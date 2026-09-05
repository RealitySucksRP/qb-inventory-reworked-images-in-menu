---------------------------
-- server/cash_sync.lua
---------------------------
-- v2.6.3 cash authority bridge
-- Physical `cash` is the canonical inventory representation while QBCore's
-- PlayerData.money.cash is kept equal so shops/framework scripts retain normal
-- buying-power behavior. Supports both stock QBCore money functions and older
-- AP/RS cores that already route cash through qb-inventory.

local cashSyncBusy = {}
local cashState = {}
local warnedMissingCashItem = false
local CASH_DRIFT_INTERVAL = 5000

local function NormalizeCashAmount(value)
    value = tonumber(value) or 0
    if value < 0 then value = 0 end
    return math.floor(value)
end

local function ResolveSource(playerOrSource)
    if type(playerOrSource) == 'table' and playerOrSource.PlayerData then
        return tonumber(playerOrSource.PlayerData.source)
    end
    return tonumber(playerOrSource)
end

local function GetPlayerCashItemCount(Player)
    local total = 0
    local items = Player and Player.PlayerData and Player.PlayerData.items or {}

    for _, item in pairs(items) do
        if item and tostring(item.name):lower() == 'cash' then
            total = total + NormalizeCashAmount(item.amount or item.count)
        end
    end

    return total
end

local function CashItemExists()
    local exists = QBCore.Shared and QBCore.Shared.Items and QBCore.Shared.Items['cash'] ~= nil
    if Config.CashAsItem and not exists and not warnedMissingCashItem then
        warnedMissingCashItem = true
        print('^1[qb-inventory] CashAsItem is enabled, but qb-core/shared/items.lua has no `cash` item. Physical cash cannot be synchronized.^7')
    end
    return exists
end

local function RememberCashState(source, Player)
    if not source or not Player then return end
    cashState[source] = {
        account = NormalizeCashAmount(Player.PlayerData.money and Player.PlayerData.money.cash),
        item = GetPlayerCashItemCount(Player)
    }
end

local function PushCashAmount(source, cashAmount)
    TriggerClientEvent('qb-inventory:client:updateCash', source, NormalizeCashAmount(cashAmount))
end

local function PushInventoryAndCash(source, Player, cashAmount)
    if not Player then return end
    TriggerClientEvent('qb-inventory:client:updateInventory', source, Player.PlayerData.items or {})
    PushCashAmount(source, cashAmount)
end

local function UpdateAccountDirect(source, Player, cashAmount, reason, notifyMoneyChange)
    if not Player then return false end

    cashAmount = NormalizeCashAmount(cashAmount)
    Player.PlayerData.money = Player.PlayerData.money or {}

    local previous = NormalizeCashAmount(Player.PlayerData.money.cash)
    Player.PlayerData.money.cash = cashAmount

    if previous ~= cashAmount then
        if Player.Functions and Player.Functions.UpdatePlayerData then
            Player.Functions.UpdatePlayerData()
        else
            TriggerClientEvent('QBCore:Player:SetPlayerData', source, Player.PlayerData)
        end

        if notifyMoneyChange ~= false then
            local difference = cashAmount - previous
            TriggerClientEvent('hud:client:OnMoneyChange', source, 'cash', math.abs(difference), difference < 0)
            TriggerClientEvent('QBCore:Client:OnMoneyChange', source, 'cash', cashAmount, 'set', reason or 'cash-item-sync')
        end
    end

    -- Do NOT manually re-fire QBCore:Server:OnMoneyChange here. Some older/custom
    -- qb-core builds incorrectly depend on the network-event global `source` in
    -- a server-to-server event handler, which produces a nil-source stack trace.
    PushCashAmount(source, cashAmount)
    RememberCashState(source, Player)
    return true
end

local function FindFirstFreeSlot(items)
    local maxSlots = tonumber(Config.MaxSlots) or 41
    for slot = 1, maxSlots do
        if items[slot] == nil then return slot end
    end
    return nil
end

local function BuildCashItem(slot, amount, existingInfo)
    local itemInfo = QBCore.Shared.Items['cash']
    return {
        name = itemInfo.name or 'cash',
        amount = NormalizeCashAmount(amount),
        info = type(existingInfo) == 'table' and existingInfo or {},
        label = itemInfo.label or 'Cash',
        description = itemInfo.description or '',
        weight = itemInfo.weight or 0,
        type = itemInfo.type or 'item',
        unique = itemInfo.unique or false,
        useable = itemInfo.useable or false,
        image = itemInfo.image or 'cash.png',
        shouldClose = itemInfo.shouldClose,
        slot = slot,
        combinable = itemInfo.combinable
    }
end

-- Set one canonical physical cash stack directly. This avoids false AddItem
-- failures, double bridge recursion, and temporary mismatch reads on older cores.
local function SetPhysicalCashTotal(source, target, reason)
    source = ResolveSource(source)
    if not source or not Config.CashAsItem or not CashItemExists() then
        return false, 'cash-item-missing'
    end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false, 'player-missing' end

    target = NormalizeCashAmount(target)
    local items = Player.PlayerData.items or {}
    local cashSlots = {}

    for slot, item in pairs(items) do
        if item and tostring(item.name):lower() == 'cash' then
            cashSlots[#cashSlots + 1] = tonumber(slot) or tonumber(item.slot)
        end
    end
    table.sort(cashSlots)

    local previous = GetPlayerCashItemCount(Player)
    local primarySlot = cashSlots[1]

    if target > 0 and not primarySlot then
        primarySlot = FindFirstFreeSlot(items)
        if not primarySlot then
            return false, 'no-free-slot'
        end
    end

    if target <= 0 then
        for _, slot in ipairs(cashSlots) do
            if slot then items[slot] = nil end
        end
    else
        local existingInfo = primarySlot and items[primarySlot] and items[primarySlot].info or {}
        items[primarySlot] = BuildCashItem(primarySlot, target, existingInfo)

        -- Consolidate any old duplicate cash stacks into the canonical slot.
        for i = 2, #cashSlots do
            local slot = cashSlots[i]
            if slot and slot ~= primarySlot then items[slot] = nil end
        end
    end

    Player.Functions.SetPlayerData('items', items)
    if ScheduleSave then ScheduleSave(source) end

    local delta = target - previous
    if delta ~= 0 then
        TriggerClientEvent('qb-inventory:client:ItemBox', source, QBCore.Shared.Items['cash'], delta > 0 and 'add' or 'remove', math.abs(delta))
    end

    PushInventoryAndCash(source, Player, target)
    RememberCashState(source, Player)
    return true
end

-- Called whenever the physical cash item changes through inventory operations.
-- The item total is authoritative and QBCore buying power is updated directly.
function RSInventorySetCashAccountFromItem(source, cashAmount, reason)
    source = ResolveSource(source)
    if not source or not Config.CashAsItem then return false end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    cashAmount = NormalizeCashAmount(cashAmount)

    -- During an account->item repair the QBCore account is already the target.
    -- Do not recurse from the generic AddItem/RemoveItem hooks.
    if cashSyncBusy[source] then
        PushCashAmount(source, cashAmount)
        RememberCashState(source, Player)
        return true
    end

    cashSyncBusy[source] = true
    local ok = UpdateAccountDirect(source, Player, cashAmount, reason or 'cash-item-sync', true)
    cashSyncBusy[source] = nil
    return ok
end

-- Called after normal QBCore AddMoney/RemoveMoney/SetMoney operations. Instead
-- of calling generic AddItem/RemoveItem, write the canonical physical stack once.
function RSInventorySyncCashFromAccount(source, reason)
    source = ResolveSource(source)
    if not source or not Config.CashAsItem then return false end
    if cashSyncBusy[source] then return true end
    if not CashItemExists() then return false end

    -- Defer while the player has a live inventory move (SetInventoryData) or
    -- drop-creation in flight -- see RSInventoryBusy in server/main.lua. This
    -- function's only write path (SetPhysicalCashTotal, below) overwrites
    -- Player.PlayerData.items directly, bypassing AddItem/RemoveItem and
    -- whatever those functions guard. Nothing stopped it from running in the
    -- middle of a drag-and-drop: a money-change event completely unrelated to
    -- what the player is doing (a paycheck, a sale, anything, on its own
    -- timer) can trigger this via QBCore:Server:OnMoneyChange, deferred one
    -- tick by SetTimeout(0). If that lands mid-move, whichever write commits
    -- last silently clobbers the other -- the mechanism behind an
    -- intermittent cash-item duplication (or loss) from repeated drop/pickup.
    --
    -- Retry rather than skip: the mismatch this call exists to fix is real
    -- and still needs correcting once the player's own move finishes. Each
    -- retry re-reads the account fresh, so a busy wait never uses stale data.
    if RSInventoryBusy and RSInventoryBusy[source] then
        SetTimeout(200, function()
            if QBCore.Functions.GetPlayer(source) then
                RSInventorySyncCashFromAccount(source, reason)
            end
        end)
        return true
    end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    local target = NormalizeCashAmount(Player.PlayerData.money and Player.PlayerData.money.cash)
    local current = GetPlayerCashItemCount(Player)

    if current == target then
        PushInventoryAndCash(source, Player, target)
        RememberCashState(source, Player)
        return true
    end

    cashSyncBusy[source] = true
    local success, failureReason = SetPhysicalCashTotal(source, target, reason or 'cash-account-sync')
    cashSyncBusy[source] = nil

    if not success then
        -- Roll hidden account buying power back only after a real, verified write
        -- failure. The old v2.6.2 path could warn even when the cash item existed.
        local actual = GetPlayerCashItemCount(Player)
        UpdateAccountDirect(source, Player, actual, 'cash-sync-rollback', true)

        local message
        if failureReason == 'no-free-slot' then
            message = 'Cash sync could not create the physical cash item because every usable inventory slot is occupied.'
        elseif failureReason == 'cash-item-missing' then
            message = 'Cash sync is unavailable because the shared `cash` item is missing.'
        else
            message = 'Cash could not be synchronized. Use /cashcheck and check the server console.'
        end

        QBCore.Functions.Notify(source, message, 'error', 7500)
        print(('[qb-inventory] Cash sync rollback source=%s requested=%s actual_item_total=%s failure=%s reason=%s')
            :format(source, target, actual, tostring(failureReason), tostring(reason)))
        return false
    end

    -- Re-read after the write. This is a hard verification, not a timing guess.
    local actual = GetPlayerCashItemCount(Player)
    if actual ~= target then
        UpdateAccountDirect(source, Player, actual, 'cash-sync-postcheck', true)
        print(('[qb-inventory] Cash post-check mismatch source=%s requested=%s actual=%s reason=%s')
            :format(source, target, actual, tostring(reason)))
        return false
    end

    PushInventoryAndCash(source, Player, actual)
    RememberCashState(source, Player)
    return true
end

-- Migration/restart rule:
--   * no physical cash + positive account cash => seed physical cash once
--   * existing physical cash => physical item remains authoritative
function RSInventoryReconcileCashOnLoad(source, reason)
    source = ResolveSource(source)
    if not source or not Config.CashAsItem then return false end
    if not CashItemExists() then return false end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end

    local accountCash = NormalizeCashAmount(Player.PlayerData.money and Player.PlayerData.money.cash)
    local itemCash = GetPlayerCashItemCount(Player)

    if itemCash == 0 and accountCash > 0 then
        print(('[qb-inventory] Migrating source %s cash account ($%s) into the physical cash item.')
            :format(source, accountCash))
        return RSInventorySyncCashFromAccount(source, reason or 'cash-load-migration')
    end

    return RSInventorySetCashAccountFromItem(source, itemCash, reason or 'cash-load-item-authority')
end

AddEventHandler('QBCore:Server:OnMoneyChange', function(playerOrSource, moneyType, amount, operation, reason)
    if not Config.CashAsItem or tostring(moneyType):lower() ~= 'cash' then return end

    local source = ResolveSource(playerOrSource)
    if not source or cashSyncBusy[source] then return end

    -- Let the core finish its own money function before reading the final total.
    SetTimeout(0, function()
        if not cashSyncBusy[source] and QBCore.Functions.GetPlayer(source) then
            RSInventorySyncCashFromAccount(source,
                ('money-event:%s:%s'):format(tostring(operation or 'unknown'), tostring(reason or 'unknown')))
        end
    end)
end)

RegisterNetEvent('qb-inventory:server:requestCashState', function()
    local source = tonumber(source)
    if not source or not Config.CashAsItem then return end
    RSInventoryReconcileCashOnLoad(source, 'client-cash-state-request')
end)

local function ClearCashState(playerOrSource)
    local source = ResolveSource(playerOrSource)
    if source then
        cashSyncBusy[source] = nil
        cashState[source] = nil
    end
end

AddEventHandler('QBCore:Server:PlayerUnloaded', ClearCashState)
AddEventHandler('QBCore:Server:OnPlayerUnload', ClearCashState)
AddEventHandler('playerDropped', function() ClearCashState(source) end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() or not Config.CashAsItem then return end

    SetTimeout(1500, function()
        if not CashItemExists() then return end

        local players = QBCore.Functions.GetPlayers()
        for key, value in pairs(players) do
            local source = tonumber(value) or tonumber(key)
            if source and QBCore.Functions.GetPlayer(source) then
                RSInventoryReconcileCashOnLoad(source, 'inventory-resource-start')
            end
        end
    end)
end)

-- Lightweight drift repair. This catches resources/core forks that alter cash
-- without emitting QBCore:Server:OnMoneyChange while avoiding repeated writes.
CreateThread(function()
    while true do
        Wait(CASH_DRIFT_INTERVAL)
        if Config.CashAsItem and CashItemExists() then
            local players = QBCore.Functions.GetPlayers()
            for key, value in pairs(players) do
                local source = tonumber(value) or tonumber(key)
                local Player = source and QBCore.Functions.GetPlayer(source) or nil
                if source and Player and not cashSyncBusy[source] then
                    local account = NormalizeCashAmount(Player.PlayerData.money and Player.PlayerData.money.cash)
                    local item = GetPlayerCashItemCount(Player)
                    local previous = cashState[source]

                    if account == item then
                        RememberCashState(source, Player)
                    elseif previous then
                        local accountChanged = account ~= previous.account
                        local itemChanged = item ~= previous.item

                        if accountChanged and not itemChanged then
                            RSInventorySyncCashFromAccount(source, 'drift-account-changed')
                        else
                            -- Item-only changes and ambiguous double changes favor
                            -- physical cash, which is the configured authority.
                            RSInventorySetCashAccountFromItem(source, item, 'drift-item-authority')
                        end
                    elseif item == 0 and account > 0 then
                        RSInventorySyncCashFromAccount(source, 'drift-initial-account')
                    else
                        RSInventorySetCashAccountFromItem(source, item, 'drift-initial-item')
                    end
                end
            end
        end
    end
end)

if QBCore.Commands and QBCore.Commands.Add then
    QBCore.Commands.Add('cashcheck', 'Check physical cash/account synchronization', {}, false, function(source)
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then return end
        local account = NormalizeCashAmount(Player.PlayerData.money and Player.PlayerData.money.cash)
        local item = GetPlayerCashItemCount(Player)
        local status = account == item and 'MATCH' or 'MISMATCH'
        QBCore.Functions.Notify(source,
            ('Cash sync %s | item $%s | QBCore $%s'):format(status, item, account),
            account == item and 'success' or 'error', 7500)
        print(('[qb-inventory] /cashcheck source=%s status=%s item=%s account=%s')
            :format(source, status, item, account))
    end, 'user')
end

exports('SyncCashFromAccount', RSInventorySyncCashFromAccount)
exports('ReconcileCashOnLoad', RSInventoryReconcileCashOnLoad)
exports('GetCashState', function(source)
    source = ResolveSource(source)
    local Player = source and QBCore.Functions.GetPlayer(source) or nil
    if not Player then return nil end
    return {
        item = GetPlayerCashItemCount(Player),
        account = NormalizeCashAmount(Player.PlayerData.money and Player.PlayerData.money.cash)
    }
end)
