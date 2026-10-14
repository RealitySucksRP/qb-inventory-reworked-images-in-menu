---------------------------
-- server/functions.lua
---------------------------

local function InitializeInventory(inventoryId, data)
    Inventories[inventoryId] = {
        items = {},
        isOpen = false,
        label = data and data.label or inventoryId,
        maxweight = data and data.maxweight or Config.StashSize.maxweight,
        slots = data and data.slots or Config.StashSize.slots
    }
    return Inventories[inventoryId]
end

function GetFirstFreeSlot(items, maxSlots)
    for i = 1, maxSlots do
        if items[i] == nil then
            return i
        end
    end
    return nil
end

local function IsReservedInventoryIdentifier(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return true end
    if identifier == 'player' then return true end
    return identifier:find('^otherplayer%-') ~= nil or
        identifier:find('^shop%-') ~= nil or
        identifier:find('^drop%-') ~= nil or
        identifier:find('^trunk%-') ~= nil or
        identifier:find('^glovebox%-') ~= nil
end

local function SetupShopItems(shopItems)
    local items = {}
    local slot = 1
    if type(shopItems) ~= 'table' then return items end

    for _, item in pairs(shopItems) do
        if type(item) == 'table' and type(item.name) == 'string' and item.name ~= '' then
            local itemInfo = QBCore.Shared.Items[item.name:lower()]
            local amount = tonumber(item.amount)
            local price = tonumber(item.price)
            local validAmount = amount and amount == math.floor(amount) and amount >= 0
                and amount ~= math.huge and amount ~= -math.huge
            local validPrice = price and price >= 0 and price ~= math.huge and price ~= -math.huge

            if itemInfo and validAmount and validPrice then
                items[slot] = {
                    name = itemInfo.name,
                    amount = amount,
                    info = type(item.info) == 'table' and item.info or {},
                    label = itemInfo.label,
                    description = itemInfo.description or '',
                    weight = itemInfo.weight,
                    type = itemInfo.type,
                    unique = itemInfo.unique,
                    useable = itemInfo.useable,
                    price = price,
                    image = itemInfo.image,
                    slot = slot,
                }
                slot = slot + 1
            else
                print(('[qb-inventory] Ignored invalid shop item definition name=%s amount=%s price=%s'):format(
                    tostring(item.name), tostring(item.amount), tostring(item.price)))
            end
        end
    end
    return items
end

-- Exported Functions

function LoadInventory(source, citizenid)
    local inventory = MySQL.prepare.await('SELECT inventory FROM players WHERE citizenid = ?', { citizenid })
    if not inventory or inventory == '' then return {} end

    local ok, decoded = pcall(json.decode, inventory)
    if not ok or type(decoded) ~= 'table' then
        print(('Invalid inventory JSON for player %s; loading an empty inventory rather than propagating corrupt data.'):format(
            source and GetPlayerName(source) or citizenid))
        return {}
    end

    local loadedInventory, rejected = SanitizeInventory(decoded, Config.MaxSlots)
    if rejected and #rejected > 0 then
        print(('The following invalid/missing inventory entries were removed for player %s: %s'):format(
            source and GetPlayerName(source) or citizenid, table.concat(rejected, ', ')))
    end
    return loadedInventory
end
exports('LoadInventory', LoadInventory)

function SaveInventory(source, offline)
    if Config.Debug then
        local debugName = offline and 'offline' or GetPlayerName(source)
        print(('[qb-inventory] Save Inventory data for: %s (%s)'):format(tostring(debugName), tostring(source)))
    end

    local PlayerData
    if offline then
        PlayerData = source
    else
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then return false end
        PlayerData = Player.PlayerData
    end
    if type(PlayerData) ~= 'table' or type(PlayerData.citizenid) ~= 'string' or PlayerData.citizenid == '' then
        return false
    end

    local items = PlayerData.items
    local ItemsJson = {}

    if items and next(items) then
        for slot, item in pairs(items) do
            if item then
                ItemsJson[#ItemsJson + 1] = {
                    name = item.name,
                    amount = item.amount,
                    info = item.info,
                    type = item.type,
                    slot = slot,
                }
            end
        end
    end

    local payload = next(ItemsJson) and json.encode(ItemsJson) or '[]'
    local ok, err = pcall(function()
        MySQL.prepare.await('UPDATE players SET inventory = ? WHERE citizenid = ?', { payload, PlayerData.citizenid })
    end)
    if not ok then
        print(('[qb-inventory] Failed saving player inventory citizenid=%s source=%s: %s')
            :format(tostring(PlayerData.citizenid), tostring(PlayerData.source or source), tostring(err)))
        return false
    end
    return true
end
exports('SaveInventory', SaveInventory)

-- Cached stash/vehicle inventories used to persist only when the UI closed.
-- A resource restart/crash after the player's inventory save but before that
-- close could therefore duplicate or lose the opposite side of a transfer.
-- Mark non-player inventories dirty on every mutation and debounce the DB write.
local dirtyInventories = {}
local stashSaveVersions = {}
local STASH_SAVE_DELAY = tonumber(Config and Config.StashSaveDelayMs) or 500

function SaveStashInventory(identifier)
    if type(identifier) ~= 'string' or identifier == '' then return false end
    local inventory = Inventories[identifier]
    if not inventory then return false end

    local version = stashSaveVersions[identifier]
    local ok, err = pcall(function()
        MySQL.prepare.await(
            'INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?',
            {identifier, json.encode(inventory.items or {}), json.encode(inventory.items or {})}
        )
    end)

    if ok then
        if version == stashSaveVersions[identifier] then
            dirtyInventories[identifier] = nil
        end
        return true
    end

    print(('[qb-inventory] Failed saving inventory %s: %s'):format(identifier, tostring(err)))
    return false
end
exports('SaveStashInventory', SaveStashInventory)

function ScheduleInventorySave(identifier)
    if type(identifier) ~= 'string' or not Inventories[identifier] then return end
    stashSaveVersions[identifier] = (stashSaveVersions[identifier] or 0) + 1
    local version = stashSaveVersions[identifier]
    dirtyInventories[identifier] = true

    SetTimeout(STASH_SAVE_DELAY, function()
        if stashSaveVersions[identifier] ~= version or not dirtyInventories[identifier] then return end
        if not Inventories[identifier] then return end
        SaveStashInventory(identifier)
    end)
end

function FlushDirtyInventories()
    local pending = {}
    for identifier in pairs(dirtyInventories) do pending[#pending + 1] = identifier end
    for _, identifier in ipairs(pending) do
        if Inventories[identifier] then SaveStashInventory(identifier) end
    end
end
exports('FlushDirtyInventories', FlushDirtyInventories)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    -- Best-effort synchronous flush of only inventories changed since their last
    -- successful write. This makes a normal `restart qb-inventory` deterministic.
    FlushDirtyInventories()
end)

-- SERVER OWNER COMPATIBILITY NOTE:
-- CashAsItem makes framework cash operations inventory operations. Any external
-- death/zombie/medical/hardcore resource calling RemoveMoney('cash'), RemoveCash,
-- or RemoveItem(cash) can remove physical cash unless the death guard blocks it.
-- A live conflict was traced with reason=zombie-death-loss. See the package
-- SERVER_OWNER_COMPATIBILITY_NOTES.md before disabling this protection.
local function IsDeathCashProtectedPlayer(player)
    if not Config.CashAsItem or GetConvarInt('qb_protect_cash_while_dead', 1) ~= 1 then return false end
    if not player or player.Offline or not player.PlayerData then return false end

    local metadata = player.PlayerData.metadata or {}
    if metadata.isdead == true or metadata.inlaststand == true then return true end

    -- Close the short race before qb-ambulancejob has replicated isdead/inlaststand.
    local src = tonumber(player.PlayerData.source)
    if src and src > 0 then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local ok, health = pcall(GetEntityHealth, ped)
            if ok and tonumber(health) and health <= 0 then return true end
        end
    end

    return false
end

local function LogBlockedDeathCash(source, amount, reason, action)
    local invoking = GetInvokingResource() or 'unknown-resource'
    print(('[qb-inventory][death-cash-guard] BLOCKED %s while dead | src=%s amount=%s reason=%s invoking=%s'):format(
        tostring(action or 'cash removal'), tostring(source), tostring(amount), tostring(reason or 'unknown'), tostring(invoking)))
    if GetConvarInt('qb_death_cash_trace', 1) == 1 and debug and debug.traceback then
        print('[qb-inventory][death-cash-guard] call trace:' .. debug.traceback('', 2))
    end
    TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'Blocked death cash removal', 'orange',
        ('**Player id:** %s | **Amount:** %s | **Action:** %s | **Reason:** %s | **Resource:** %s'):format(
            tostring(source), tostring(amount), tostring(action or 'cash removal'), tostring(reason or 'unknown'), tostring(invoking)))
end

function AddCash(source, amount, reason)
    if not source or not amount then return false end
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false end

    local PlayerObject = QBCore.Functions.GetPlayer(source)
    if not PlayerObject then return false end
    reason = reason or 'unknown'

    if Config.CashAsItem then
        if not QBCore.Shared.Items[Config.CashItemName or 'cash'] then
            print(('[qb-inventory] CashAsItem is true, but qb-core/shared/items.lua is missing item: %s'):format(Config.CashItemName or 'cash'))
            return false
        end

        return AddItem(source, Config.CashItemName or 'cash', amount, nil, {}, 'money_as_item:add (' .. reason .. ')')
    end

    return PlayerObject.Functions.AddMoney('cash', amount, reason)
end
exports('AddCash', AddCash)

function RemoveCash(source, amount, reason)
    if not source or not amount then return false end
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false end

    local PlayerObject = QBCore.Functions.GetPlayer(source)
    if not PlayerObject then return false end
    reason = reason or 'unknown'

    if IsDeathCashProtectedPlayer(PlayerObject) then
        LogBlockedDeathCash(source, amount, reason, 'RemoveCash')
        return false
    end

    if Config.CashAsItem then
        if not QBCore.Shared.Items[Config.CashItemName or 'cash'] then
            print(('[qb-inventory] CashAsItem is true, but qb-core/shared/items.lua is missing item: %s'):format(Config.CashItemName or 'cash'))
            return false
        end

        if HasItem(source, Config.CashItemName or 'cash', amount) then
            return RemoveItem(source, Config.CashItemName or 'cash', amount, nil, 'money_as_item:remove (' .. reason .. ')')
        end

        return false
    end

    return PlayerObject.Functions.RemoveMoney('cash', amount, reason)
end
exports('RemoveCash', RemoveCash)

local PreserveCashInReplacementInventory

function SetInventory(identifier, items, reason)
    local player = QBCore.Functions.GetPlayer(identifier)
    if not player and not Inventories[identifier] and not Drops[identifier] then
        print('SetInventory: Inventory not found for ' .. tostring(identifier))
        return false
    end
    if type(items) ~= 'table' then return false end

    local maxSlots = player and Config.MaxSlots or
        (Inventories[identifier] and (Inventories[identifier].slots or Config.StashSize.slots)) or
        (Drops[identifier] and (Drops[identifier].slots or Config.DropSize.slots))

    if player then
        items = PreserveCashInReplacementInventory(player, items)
        if not items then return false end
    end

    local sanitized, rejected = SanitizeInventory(items, maxSlots)
    if rejected and #rejected > 0 then
        print(('[qb-inventory] SetInventory rejected malformed/unknown entries inventory=%s entries=%s')
            :format(tostring(identifier), table.concat(rejected, ', ')))
    end
    items = sanitized

    if player then
        player.Functions.SetPlayerData('items', items)
        ScheduleSave(identifier)
        if Config.CashAsItem and RSInventorySetCashAccountFromItem then
            RSInventorySetCashAccountFromItem(identifier, GetItemCount(identifier, Config.CashItemName or 'cash') or 0,
                                              'set-inventory')
        end
        if not player.Offline then
            local logMessage = string.format('**%s (citizenid: %s | id: %s)** items set: %s', GetPlayerName(identifier), player.PlayerData.citizenid, identifier, json.encode(items))
            TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'SetInventory', 'blue', logMessage)
        end
    elseif Drops[identifier] then
        Drops[identifier].items = items
    elseif Inventories[identifier] then
        Inventories[identifier].items = items
        ScheduleInventorySave(identifier)
    end

    local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier
    local setReason = reason or 'No reason specified'
    local resourceName = GetInvokingResource() or 'qb-inventory'
    TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'Inventory Set', 'blue', '**Inventory:** ' .. invName .. '\n' .. '**Items:** ' .. json.encode(items) .. '\n' .. '**Reason:** ' .. setReason .. '\n' .. '**Resource:** ' .. resourceName)
    return true
end
exports('SetInventory', SetInventory)

function SetItemData(source, itemName, key, val, slot)
    if not itemName or not key then return false end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local item
    if slot then
        item = Player.PlayerData.items[tonumber(slot)]
        if not item or item.name:lower() ~= itemName:lower() then return false end
    else
        item = GetItemByName(source, itemName)
        if not item then return false end
    end
    item[key] = val
    Player.PlayerData.items[item.slot] = item
    Player.Functions.SetPlayerData('items', Player.PlayerData.items)
    ScheduleSave(source)
    return true
end

exports('SetItemData', SetItemData)

function UseItem(itemName, ...)
    local itemData = QBCore.Functions.CanUseItem(itemName)
    if type(itemData) == 'function' then
        itemData(...)
    elseif type(itemData) == 'table' and itemData.func then
        itemData.func(...)
    end
end
exports('UseItem', UseItem)

function GetSlotsByItem(items, itemName)
    local slotsFound = {}
    if not items then return slotsFound end
    for slot, item in pairs(items) do
        if item.name:lower() == itemName:lower() then
            slotsFound[#slotsFound + 1] = slot
        end
    end
    return slotsFound
end
exports('GetSlotsByItem', GetSlotsByItem)

function GetFirstSlotByItem(items, itemName)
    if not items then return end
    for slot, item in pairs(items) do
        if item.name:lower() == itemName:lower() then
            return tonumber(slot)
        end
    end
    return nil
end
exports('GetFirstSlotByItem', GetFirstSlotByItem)

function GetItemBySlot(source, slot)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local items = Player.PlayerData.items
    return items[tonumber(slot)]
end
exports('GetItemBySlot', GetItemBySlot)

function GetTotalWeight(items)
    if type(items) ~= 'table' then return 0 end
    local weight = 0
    for _, item in pairs(items) do
        if type(item) == 'table' then
            local amount = tonumber(item.amount or item.count)
            if amount and amount > 0 then
                local itemInfo = type(item.name) == 'string' and QBCore.Shared.Items[item.name:lower()] or nil
                local unitWeight = itemInfo and tonumber(itemInfo.weight) or tonumber(item.weight)
                if unitWeight and unitWeight > 0 then
                    weight = weight + (unitWeight * amount)
                end
            end
        end
    end
    return tonumber(weight) or 0
end
exports('GetTotalWeight', GetTotalWeight)

function GetItemByName(source, item)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local items = Player.PlayerData.items
    local slot = GetFirstSlotByItem(items, tostring(item):lower())
    return items[slot]
end
exports('GetItemByName', GetItemByName)

function GetItemsByName(source, item)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local PlayerItems = Player.PlayerData.items
    item = tostring(item):lower()
    local items = {}
    for _, slot in pairs(GetSlotsByItem(PlayerItems, item)) do
        if slot then
            items[#items + 1] = PlayerItems[slot]
        end
    end
    return items
end
exports('GetItemsByName', GetItemsByName)

function GetSlots(identifier)
    local inventory, maxSlots
    local player = QBCore.Functions.GetPlayer(identifier)
    if player then
        inventory = player.PlayerData.items
        maxSlots = Config.MaxSlots
    elseif Inventories[identifier] then
        inventory = Inventories[identifier].items
        maxSlots = Inventories[identifier].slots
    elseif Drops[identifier] then
        inventory = Drops[identifier].items
        maxSlots = Drops[identifier].slots
    end
    if not inventory then return 0, maxSlots or Config.MaxSlots end
    local slotsUsed = 0
    for _, v in pairs(inventory) do
        if v then
            slotsUsed = slotsUsed + 1
        end
    end
    local slotsFree = (maxSlots or Config.MaxSlots) - slotsUsed
    return slotsUsed, slotsFree
end
exports('GetSlots', GetSlots)

function GetItemCount(source, items)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local isTable = type(items) == 'table'
    local itemsSet = isTable and {} or nil
    if isTable then
        for _, item in pairs(items) do
            itemsSet[item] = true
        end
    end
    local count = 0
    for _, item in pairs(Player.PlayerData.items) do
        if (isTable and itemsSet[item.name]) or (not isTable and items == item.name) then
            count = count + item.amount
        end
    end
    return count
end
exports('GetItemCount', GetItemCount)

function CanAddItem(identifier, item, amount)
    if type(item) ~= 'string' or item == '' then return false end
    amount = tonumber(amount)
    if not amount or amount ~= math.floor(amount) or amount <= 0 then return false end
    item = item:lower()

    local Player = QBCore.Functions.GetPlayer(identifier)
    local itemData = QBCore.Shared.Items[item]
    if not itemData then return false end

    local inventory, items
     if Player then
        inventory = { maxweight = Config.MaxWeight, slots = Config.MaxSlots }
        items = Player.PlayerData.items
    elseif Inventories[identifier] then
        inventory = Inventories[identifier]
        items = Inventories[identifier].items
    elseif Drops[identifier] then
        inventory = Drops[identifier]
        items = Drops[identifier].items
    end

    if not inventory then return false end

    local weight = itemData.weight * amount
    local totalWeight = GetTotalWeight(items) + weight
    if totalWeight > inventory.maxweight then
        return false, 'weight'
    end

    if not itemData.unique then
        for _, v in pairs(items) do
            if v.name == itemData.name then
                return true
            end
        end
    end

    local slotsUsed, _ = GetSlots(identifier)
    if slotsUsed >= inventory.slots then
        return false, 'slots'
    end

    return true
end
exports('CanAddItem', CanAddItem)

function GetFreeWeight(source)
    if not source then warn('Source was not passed into GetFreeWeight') return 0 end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return 0 end

    local totalWeight = GetTotalWeight(Player.PlayerData.items)
    return Config.MaxWeight - totalWeight
end
exports('GetFreeWeight', GetFreeWeight)

local function GetConfiguredCashItemName()
    local name = Config.CashItemName
    if type(name) ~= 'string' or name == '' then name = 'cash' end
    return name:lower()
end

local function IsConfiguredCashItem(itemData)
    return itemData and type(itemData.name) == 'string' and itemData.name:lower() == GetConfiguredCashItemName()
end

PreserveCashInReplacementInventory = function(player, replacementItems)
    if not Config.CashAsItem or not player then return replacementItems end

    replacementItems = type(replacementItems) == 'table' and replacementItems or {}

    -- If the caller explicitly supplied a cash stack, treat that as intentional
    -- and let the normal cash sync below reconcile the account to it.
    for _, itemData in pairs(replacementItems) do
        if IsConfiguredCashItem(itemData) then return replacementItems end
    end

    local existingCash = {}
    for _, itemData in pairs(player.PlayerData.items or {}) do
        if IsConfiguredCashItem(itemData) then
            existingCash[#existingCash + 1] = itemData
        end
    end
    if #existingCash == 0 then return replacementItems end

    local function firstFreeSlot(preferred)
        preferred = tonumber(preferred)
        if preferred and preferred >= 1 and preferred <= Config.MaxSlots and replacementItems[preferred] == nil then
            return preferred
        end
        for slot = 1, Config.MaxSlots do
            if replacementItems[slot] == nil then return slot end
        end
        return nil
    end

    for _, itemData in ipairs(existingCash) do
        local slot = firstFreeSlot(itemData.slot)
        if not slot then
            print(('[qb-inventory] BLOCKED SetInventory cash loss for source=%s: replacement inventory has no free slot for protected %s.'):format(
                tostring(player.PlayerData.source), GetConfiguredCashItemName()))
            return nil
        end
        local preserved = {}
        for key, value in pairs(itemData) do preserved[key] = value end
        preserved.slot = slot
        replacementItems[slot] = preserved
    end

    return replacementItems
end

local function SchedulePostClearCashRepair(source)
    if not Config.CashAsItem then return end

    -- A number of ambulance/medical resources call ClearInventory() and then
    -- immediately perform their own inventory write. If that second write drops
    -- the physical cash stack, the cash drift reconciler would otherwise accept
    -- zero as authoritative and erase PlayerData.money.cash too. Re-read the
    -- account after the clear and let the normal cash bridge rebuild the physical
    -- stack if an external wipe raced us. The account is read fresh on every pass,
    -- so legitimate cash changes are never restored to an old snapshot.
    for _, delay in ipairs({ 150, 750, 3000 }) do
        local delayMs = delay
        SetTimeout(delayMs, function()
            if QBCore.Functions.GetPlayer(source) then
                if RSInventorySyncCashFromAccount then
                    RSInventorySyncCashFromAccount(source, ('post-clear-repair:%sms'):format(delayMs))
                end

                -- Also rewrite the DB inventory from the authoritative live player
                -- state. Some ambulance forks perform a raw SQL inventory wipe
                -- immediately after ClearInventory(), bypassing this resource's
                -- preservation logic entirely. Death is infrequent enough that
                -- three guarded writes are preferable to permanent cash loss.
                SaveInventory(source)
            end
        end)
    end
end

function ClearInventory(source, filterItems)
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return end

    local savedItemData = {}
    if Config.CashAsItem then
        for slot, itemData in pairs(player.PlayerData.items or {}) do
            if IsConfiguredCashItem(itemData) then
                savedItemData[slot] = itemData
            end
        end
    end

    if filterItems then
        local itemsToFilter = type(filterItems) == 'string' and {filterItems} or filterItems
        for _, itemName in ipairs(itemsToFilter) do
            local items = GetItemsByName(source, itemName)
            for _, item in ipairs(items) do
                if item and not savedItemData[item.slot] then
                    savedItemData[item.slot] = item
                end
            end
        end
    end

    player.Functions.SetPlayerData('items', savedItemData)

    if Config.CashAsItem and RSInventorySetCashAccountFromItem then
        local cashTotal = GetItemCount(source, GetConfiguredCashItemName()) or 0
        RSInventorySetCashAccountFromItem(source, cashTotal, 'clear-inventory-preserve-cash')
    end

    ScheduleSave(source)
    SchedulePostClearCashRepair(source)

    if not player.Offline then
        local logMessage = string.format('**%s (citizenid: %s | id: %s)** inventory cleared', GetPlayerName(source), player.PlayerData.citizenid, source)
        TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'ClearInventory', 'red', logMessage)
        local ped = GetPlayerPed(source)
        local weapon = GetSelectedPedWeapon(ped)
        if weapon ~= `WEAPON_UNARMED` then
            local weaponIsSaved = false
            for _, savedItem in pairs(savedItemData) do
                if savedItem.type == 'weapon' and QBCore.Shared.Weapons[weapon] and QBCore.Shared.Weapons[weapon].name == savedItem.name then
                    weaponIsSaved = true
                    break
                end
            end
            if not weaponIsSaved then
                RemoveWeaponFromPed(ped, weapon)
            end
        end
        if Player(source).state.inv_busy then
            TriggerClientEvent('qb-inventory:client:updateInventory', source, player.PlayerData.items)
        end
        if Config.CashAsItem then
            TriggerClientEvent('qb-inventory:client:updateCash', source, GetItemCount(source, GetConfiguredCashItemName()) or 0)
        end
    end
end
exports('ClearInventory', ClearInventory)

function HasItem(source, items, amount)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Player.PlayerData.items then return false end
    local playerItems = Player.PlayerData.items
    if type(items) ~= 'table' then
        local itemName = items
        local requiredAmount = amount or 1
        local totalAmount = 0
        for _, itemData in pairs(playerItems) do
            if itemData and itemData.name == itemName then
                totalAmount = totalAmount + itemData.amount
            end
        end
        return totalAmount >= requiredAmount
    else
        for itemName, requiredAmount in pairs(items) do
            if table.type(items) == 'array' then
                itemName = requiredAmount
                requiredAmount = amount or 1
            end
            local totalAmount = 0
            for _, itemData in pairs(playerItems) do
                if itemData and itemData.name == itemName then
                    totalAmount = totalAmount + itemData.amount
                end
            end

            if totalAmount < requiredAmount then
                return false
            end
        end
        return true
    end
end
exports('HasItem', HasItem)

function CloseInventory(source, identifier)
    source = tonumber(source)
    if not source then return end

    local session = GetInventorySession(source)
    if not identifier and session then identifier = session.name end

    if type(identifier) == 'string' then
        local targetId = tonumber(identifier:match('^otherplayer%-(%d+)$'))
        if targetId and QBCore.Functions.GetPlayer(targetId) then
            Player(targetId).state.inv_busy = false
        elseif Drops[identifier] then
            if Drops[identifier].isOpen == source then
                Drops[identifier].isOpen = false
            end
        elseif Inventories[identifier] and Inventories[identifier].isOpen == source then
            Inventories[identifier].isOpen = false
            SaveStashInventory(identifier)
        end
    end

    CleanupInventorySession(source, true)
    if QBCore.Functions.GetPlayer(source) then
        Player(source).state.inv_busy = false
    end
    TriggerClientEvent('qb-inventory:client:closeInv', source)
end
exports('CloseInventory', CloseInventory)

function OpenInventoryById(source, targetId)
    source = tonumber(source)
    targetId = tonumber(targetId)
    if not source or not targetId or source == targetId then return false end

    local QBPlayer = QBCore.Functions.GetPlayer(source)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
    if not QBPlayer or not TargetPlayer then return false end

    -- The stock QBCore admin menu calls this export server-side and expects to
    -- inspect a player remotely. Client/robbery calls arrive with no invoking
    -- server resource and remain subject to bucket + distance validation.
    local invokingResource = GetInvokingResource()
    local trustedRemote = type(invokingResource) == 'string' and invokingResource ~= '' and
                              invokingResource ~= GetCurrentResourceName()
    if not trustedRemote and SameInventoryRoutingBucket and
        not SameInventoryRoutingBucket(source, targetId) then
        return false
    end
    if IsInventoryServerBusy(source) or IsInventoryServerBusy(targetId) then
        return false
    end

    -- Acquire the server-only victim lock before exposing the target inventory.
    -- Replicated inv_busy is compatibility/UI state only and is never trusted as
    -- the mutual-exclusion primitive.
    if not SetInventorySession(source, 'otherplayer-' .. targetId,
                               trustedRemote and 'trusted-otherplayer' or 'otherplayer',
                               { trustedRemote = trustedRemote }) then
        return false
    end
    Player(source).state.inv_busy = true
    Player(targetId).state.inv_busy = true

    local formattedInventory = {
        name = 'otherplayer-' .. targetId,
        label = GetPlayerName(targetId),
        maxweight = Config.MaxWeight,
        slots = Config.MaxSlots,
        inventory = TargetPlayer.PlayerData.items
    }
    TriggerClientEvent('qb-inventory:client:openInventory', source,
                       QBPlayer.PlayerData.items, formattedInventory)
    return true
end
exports('OpenInventoryById', OpenInventoryById)

function ClearStash(identifier)
    if not identifier then return end
    local inventory = Inventories[identifier]
    if not inventory then return end
    inventory.items = {}
    ScheduleInventorySave(identifier)
    SaveStashInventory(identifier)
end
exports('ClearStash', ClearStash)

function CreateShop(shopData)
    if type(shopData) ~= 'table' then return false end

    if shopData.name then
        if type(shopData.name) ~= 'string' or shopData.name == '' then return false end
        local items = SetupShopItems(shopData.items)
        RegisteredShops[shopData.name] = {
            name = shopData.name,
            label = shopData.label,
            coords = shopData.coords,
            bucket = shopData.bucket,
            slots = #items,
            items = items
        }
        return true
    end

    for key, data in pairs(shopData) do
        if type(data) == 'table' then
            if data.name then
                local shopName = type(key) == 'number' and data.name or key
                if type(shopName) == 'string' and shopName ~= '' then
                    local items = SetupShopItems(data.items)
                    RegisteredShops[shopName] = {
                        name = shopName,
                        label = data.label,
                        coords = data.coords,
                        bucket = data.bucket,
                        slots = #items,
                        items = items
                    }
                end
            else
                CreateShop(data)
            end
        end
    end
    return true
end
exports('CreateShop', CreateShop)

function OpenShop(source, name)
    if not name then return end
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or IsInventoryServerBusy(source) then return end
    if not RegisteredShops[name] then return end
    local shopBucket = RegisteredShops[name].bucket
    local sourceBucket = GetInventoryRoutingBucket and GetInventoryRoutingBucket(source) or nil
    if shopBucket ~= nil and sourceBucket ~= nil and tonumber(shopBucket) ~= sourceBucket then return end
    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 then return end
    local playerCoords = GetEntityCoords(playerPed)
    local shopCoords = RegisteredShops[name].coords and NormalizeInventoryCoords(RegisteredShops[name].coords) or nil
    if RegisteredShops[name].coords and not shopCoords then return end
    if shopCoords and #(playerCoords - shopCoords) > (tonumber(Config.ShopAccessDistance) or 6.0) then return end
    local formattedInventory = {
        name = 'shop-' .. RegisteredShops[name].name,
        label = RegisteredShops[name].label,
        maxweight = 5000000,
        slots = #RegisteredShops[name].items,
        inventory = RegisteredShops[name].items
    }
    if not SetInventorySession(source, 'shop-' .. RegisteredShops[name].name, 'shop', {
        anchor = RegisteredShops[name].coords,
        bucket = RegisteredShops[name].bucket,
        accessDistance = Config.ShopAccessDistance,
    }) then return end
    Player(source).state.inv_busy = true
    TriggerClientEvent('qb-inventory:client:sendServerTime', source, os.time())
    TriggerClientEvent('qb-inventory:client:openInventory', source, Player.PlayerData.items, formattedInventory)
end
exports('OpenShop', OpenShop)

function OpenInventory(source, identifier, data)
    source = tonumber(source)
    if not source then return end
    local QBPlayer = QBCore.Functions.GetPlayer(source)
    if not QBPlayer then return end
    if IsInventoryServerBusy(source) then return end
    if not identifier then
        if not SetInventorySession(source, 'player', 'player') then return end
        Player(source).state.inv_busy = true
        TriggerClientEvent('qb-inventory:client:openInventory', source, QBPlayer.PlayerData.items)
        return
    end
    if type(identifier) ~= 'string' or identifier == '' then
        print('Inventory tried to open an invalid identifier')
        return
    end

    local sessionKind = (data and data.sessionKind) or 'stash'
    local sessionContext = (data and type(data.sessionContext) == 'table') and data.sessionContext or {}
    local vehicleNamespace = identifier:find('^trunk%-') or identifier:find('^glovebox%-')
    if IsReservedInventoryIdentifier(identifier) then
        local validVehicleNamespace = vehicleNamespace and sessionKind == 'vehicle' and tonumber(sessionContext.netId)
        if not validVehicleNamespace then
            print(('[qb-inventory] Refused generic OpenInventory on reserved identifier: %s'):format(identifier))
            return
        end
    end

    local inventory = Inventories[identifier]
    if not inventory then
        local result = MySQL.prepare.await('SELECT * FROM inventories WHERE identifier = ?', { identifier })
        if result and result[1] then
         --   print(('Loaded inventory [%s] from database.'):format(identifier))
            local decoded = {}
            if type(result[1].items) == 'string' and result[1].items ~= '' then
                local ok, parsed = pcall(json.decode, result[1].items)
                if ok and type(parsed) == 'table' then
                    decoded = parsed
                else
                    print(('[qb-inventory] Invalid JSON in inventory %s; loaded empty rather than crashing the open path.'):format(
                        tostring(identifier)))
                end
            end
            local inventorySlots = (data and data.slots) or Config.StashSize.slots
            Inventories[identifier] = {
                items = SanitizeInventory(decoded, inventorySlots),
                isOpen = false,
                label = (data and data.label) or identifier,
                maxweight = (data and data.maxweight) or Config.StashSize.maxweight,
                slots = inventorySlots
            }
            inventory = Inventories[identifier]
        else
         --   print(('Initializing new inventory for [%s].'):format(identifier))
            inventory = InitializeInventory(identifier, data)
        end
    end
    if inventory and inventory.isOpen and inventory.isOpen ~= source then
        TriggerClientEvent('QBCore:Notify', source, 'This inventory is currently in use', 'error')
        return
    end
    inventory.maxweight = (data and data.maxweight) or (inventory and inventory.maxweight) or Config.StashSize.maxweight
    inventory.slots = (data and data.slots) or (inventory and inventory.slots) or Config.StashSize.slots
    inventory.label = (data and data.label) or (inventory and inventory.label) or identifier

    local formattedInventory = { name = identifier, label = inventory.label, maxweight = inventory.maxweight, slots = inventory.slots, inventory = inventory.items }
    if data and data.coords and not sessionContext.anchor then sessionContext.anchor = data.coords end
    if data and data.accessDistance and not sessionContext.accessDistance then sessionContext.accessDistance = data.accessDistance end
    if not SetInventorySession(source, identifier, sessionKind, sessionContext) then return end
    inventory.isOpen = source
    Player(source).state.inv_busy = true
    TriggerClientEvent('qb-inventory:client:sendServerTime', source, os.time())
    TriggerClientEvent('qb-inventory:client:openInventory', source, QBPlayer.PlayerData.items, formattedInventory)
end
exports('OpenInventory', OpenInventory)

function CreateInventory(identifier, data)
    if type(identifier) ~= 'string' or identifier == '' then return false end
    if IsReservedInventoryIdentifier(identifier) then
        print(('[qb-inventory] Refused CreateInventory on reserved identifier: %s'):format(identifier))
        return false
    end
    if Inventories[identifier] then return false end
    Inventories[identifier] = InitializeInventory(identifier, data)
    return true
end
exports('CreateInventory', CreateInventory)

function GetInventory(identifier)
    return Inventories[identifier]
end
exports('GetInventory', GetInventory)

function RemoveInventory(identifier)
    if not Inventories[identifier] then return true end

    -- Never evict dirty cached data after a failed database write. External
    -- resources may call this export during cleanup; dropping the cache anyway
    -- would turn a transient oxmysql failure into permanent inventory loss.
    if dirtyInventories[identifier] and not SaveStashInventory(identifier) then
        print(('[qb-inventory] Refusing to remove dirty inventory %s because its save failed.'):format(
            tostring(identifier)))
        return false
    end

    Inventories[identifier] = nil
    dirtyInventories[identifier] = nil
    stashSaveVersions[identifier] = nil
    return true
end
exports('RemoveInventory', RemoveInventory)

function AddItem(identifier, item, amount, slot, info, reason)
    if type(item) ~= 'string' or item == '' then
        print('AddItem: Refused invalid item name "' .. tostring(item) .. '"')
        return false
    end
    item = item:lower()

    amount = amount == nil and 1 or tonumber(amount)
    if not amount or amount ~= math.floor(amount) or amount <= 0 then
        print('AddItem: Refused invalid amount for "' .. tostring(item) .. '"')
        return false
    end

    if slot ~= nil and slot ~= false then
        slot = tonumber(slot)
        if not slot or slot ~= math.floor(slot) or slot < 1 then
            print('AddItem: Refused invalid slot for "' .. tostring(item) .. '"')
            return false
        end
    else
        slot = nil
    end

    local itemInfo = QBCore.Shared.Items[item]
    if not itemInfo then
        print('AddItem: Invalid item "' .. tostring(item) .. '"')
        return false
    end

    local player = QBCore.Functions.GetPlayer(identifier)
    local inventory, inventoryWeight, inventorySlots
    local inventoryType = nil

    if player then
        inventory, inventoryWeight, inventorySlots = player.PlayerData.items, Config.MaxWeight, Config.MaxSlots
        inventoryType = 'player'
    elseif Inventories[identifier] then
        inventory = Inventories[identifier].items
        inventoryWeight = Inventories[identifier].maxweight or Config.StashSize.maxweight
        inventorySlots = Inventories[identifier].slots or Config.StashSize.slots
        inventoryType = 'stash'
    elseif Drops[identifier] then
        inventory, inventoryWeight, inventorySlots = Drops[identifier].items, Drops[identifier].maxweight, Drops[identifier].slots
        inventoryType = 'drop'
    else
        print('AddItem: Inventory not found for ' .. tostring(identifier))
        return false
    end

    if slot and slot > inventorySlots then
        return false
    end

    if GetTotalWeight(inventory) + (itemInfo.weight * amount) > inventoryWeight then
        return false
    end

    if slot and inventory[slot] and
        (itemInfo.unique or inventory[slot].name ~= item) then
        -- Explicit slots are authoritative; never overwrite an occupied slot.
        return false
    end

    local updated = false

    if not itemInfo.unique then
        local allowExpiryMerge = Config.StackWithDifferentExpiry ~= false
        local targetSlot = slot
        if not targetSlot then
            for k, v in pairs(inventory) do
                if v.name == item then
                    local canStack = true
                    if not allowExpiryMerge and type(v.info) == 'table' and v.info.expiryDate then
                        if type(info) ~= 'table' or not info.expiryDate or info.expiryDate ~= v.info.expiryDate then
                            canStack = false
                        end
                    end
                    if canStack then
                        targetSlot = k
                        break
                    end
                end
            end
        end

        if targetSlot and inventory[targetSlot] and inventory[targetSlot].name == item then
            local stackItem = inventory[targetSlot]
            stackItem.amount = stackItem.amount + amount

            -- Merged stacks keep the earlier expiry so stacking never extends item life.
            local incomingExpiry = type(info) == 'table' and info.expiryDate or nil
            if incomingExpiry then
                if type(stackItem.info) ~= 'table' then stackItem.info = {} end
                local currentExpiry = stackItem.info.expiryDate
                stackItem.info.expiryDate = (currentExpiry and math.min(currentExpiry, incomingExpiry)) or incomingExpiry
                if not stackItem.info.creationDate and type(info) == 'table' and info.creationDate then
                    stackItem.info.creationDate = info.creationDate
                end
            end

            updated = true
            slot = targetSlot
        end
    end

    if not updated then
        slot = slot or GetFirstFreeSlot(inventory, inventorySlots)
        if not slot then
            return false
        end

        -- info can arrive as '' or json strings from legacy saves; only tables are usable.
        local newItemInfo = type(info) == 'table' and info or {}
        local currentTime = os.time()

        if itemInfo.decayrate and not newItemInfo.expiryDate then
            newItemInfo.creationDate = currentTime
            newItemInfo.expiryDate = currentTime + itemInfo.decayrate
        elseif not newItemInfo.creationDate then
            newItemInfo.creationDate = currentTime
        end

        inventory[slot] = {
            name = item,
            amount = amount,
            info = newItemInfo,
            label = itemInfo.label,
            description = itemInfo.description or '',
            weight = itemInfo.weight,
            type = itemInfo.type,
            unique = itemInfo.unique,
            useable = itemInfo.useable,
            image = itemInfo.image,
            shouldClose = itemInfo.shouldClose,
            slot = slot,
            combinable = itemInfo.combinable
        }

        if itemInfo.type == 'weapon' then
            if not inventory[slot].info.serie then
                inventory[slot].info.serie = tostring(QBCore.Shared.RandomInt(2) .. QBCore.Shared.RandomStr(3) .. QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2) .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(4))
            end
            if not inventory[slot].info.quality then
                inventory[slot].info.quality = 100
            end
        end
    end
    if inventoryType == 'player' then
        player.Functions.SetPlayerData('items', inventory)
        ScheduleSave(identifier)
        if item == (Config.CashItemName or 'cash') and Config.CashAsItem then
            local cashTotal = GetItemCount(identifier, Config.CashItemName or 'cash') or 0
            if RSInventorySetCashAccountFromItem then
                RSInventorySetCashAccountFromItem(identifier, cashTotal, 'cash-item-added')
            else
                player.Functions.SetMoney('cash', cashTotal, 'cash-item-added-fallback')
            end
        end
        TriggerClientEvent('qb-inventory:client:ItemBox', identifier, itemInfo, 'add', amount)
        TriggerClientEvent('qb-inventory:client:updateInventory', identifier, player.PlayerData.items)
    elseif inventoryType == 'stash' then
        Inventories[identifier].items = inventory
        ScheduleInventorySave(identifier)
    elseif inventoryType == 'drop' then
        Drops[identifier].items = inventory
    end

    local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier
    local addReason = reason or 'No reason specified'
    local resourceName = GetInvokingResource() or 'qb-inventory'
    TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'Item Added', 'green', '**Inventory:** ' .. invName .. ' (Slot: ' .. tostring(slot) .. ')\n' .. '**Item:** ' .. item .. '\n' .. '**Amount:** ' .. amount .. '\n' .. '**Reason:** ' .. addReason .. '\n' .. '**Resource:** ' .. resourceName)
    
    return true
end
exports('AddItem', AddItem)

function RemoveItem(identifier, item, amount, slot, reason)
    if type(item) ~= 'string' or item == '' then
        return false
    end
    item = item:lower()

    -- ==================== REMOVEITEM DEBUG START ====================
    --print('--- REMOVEITEM DEBUG: Function Called ---')
    --print(('Attempting to remove %s of "%s" from inventory [%s], slot [%s]'):format(tostring(amount), tostring(item), tostring(identifier), tostring(slot)))
    -- ================================================================

    local player = QBCore.Functions.GetPlayer(identifier)
    local inventory, inventoryType, inventorySlots

    -- Final authority guard for scripts that bypass QBCore RemoveMoney and call
    -- qb-inventory:RemoveItem('cash', ...) directly while the player is dead.
    if player and item == (Config.CashItemName or 'cash'):lower() and IsDeathCashProtectedPlayer(player) then
        LogBlockedDeathCash(identifier, amount, reason, 'RemoveItem(' .. item .. ')')
        return false
    end

    if player then
        inventory, inventoryType, inventorySlots = player.PlayerData.items, 'player', Config.MaxSlots
    elseif Inventories[identifier] then
        inventory, inventoryType = Inventories[identifier].items, 'stash'
        inventorySlots = Inventories[identifier].slots or Config.StashSize.slots
    elseif Drops[identifier] then
        inventory, inventoryType = Drops[identifier].items, 'drop'
        inventorySlots = Drops[identifier].slots or Config.DropSize.slots
    else
        if Config.Debug then
            print('REMOVEITEM DEBUG: FAILED - Inventory not found for ' .. tostring(identifier))
        end
        return false
    end

    amount = tonumber(amount)
    if not amount or amount ~= math.floor(amount) or amount <= 0 then
        if Config.Debug then
            print('REMOVEITEM DEBUG: FAILED - Invalid amount: ' .. tostring(amount))
        end
        return false
    end

    if slot ~= nil and slot ~= false then
        slot = tonumber(slot)
        if not slot or slot ~= math.floor(slot) or slot < 1 or
            slot > inventorySlots then
            return false
        end
    else
        slot = nil
    end

    local itemName = item
    local itemInfo = QBCore.Shared.Items[itemName]
    if not itemInfo then
        if Config.Debug then
            print('REMOVEITEM DEBUG: FAILED - Item info not found for ' .. itemName)
        end
        return false
    end
    local currentAmount = 0
    for _, itemData in pairs(inventory) do
        if itemData and itemData.name == itemName then
            currentAmount = currentAmount + itemData.amount
        end
    end
    if currentAmount < amount then
        if Config.Debug then
            print(('REMOVEITEM DEBUG: FAILED - Not enough total items. Have: %s, Need: %s'):format(currentAmount, amount))
        end
        return false
    end

    local amountToRemove = amount

    if slot then
        local itemInSlot = inventory[slot]

        if not itemInSlot then
            if Config.Debug then
                print('REMOVEITEM DEBUG: FAILED - No item found in slot ' .. slot)
            end
            return false
        end

        if itemInSlot.name ~= itemName then
            if Config.Debug then
                print(('REMOVEITEM DEBUG: FAILED - Item name mismatch. Expected: "%s", Found: "%s"'):format(itemName, itemInSlot.name))
            end
            return false
        end
        
        if itemInSlot.amount < amountToRemove then
            if Config.Debug then
                print(('REMOVEITEM DEBUG: FAILED - Not enough amount in slot. Have: %s, Need: %s'):format(itemInSlot.amount, amountToRemove))
            end
            return false
        end

        itemInSlot.amount = itemInSlot.amount - amountToRemove
        if itemInSlot.amount <= 0 then 
            inventory[slot] = nil
        end
        amountToRemove = 0
    else
        local slots = {}
        for k in pairs(inventory) do table.insert(slots, k) end
        table.sort(slots)

        for _, slotKey in ipairs(slots) do
            if amountToRemove <= 0 then break end
            local invItem = inventory[slotKey]
            if invItem and invItem.name == itemName then
                if invItem.amount > amountToRemove then
                    invItem.amount = invItem.amount - amountToRemove
                    amountToRemove = 0
                else
                    amountToRemove = amountToRemove - invItem.amount
                    inventory[slotKey] = nil
                end
            end
        end
    end

    if amountToRemove > 0 then
        if Config.Debug then
            print('REMOVEITEM DEBUG: FAILED - Could not remove the full amount required.')
        end
        return false
    end
    
    if inventoryType == 'player' then
        player.Functions.SetPlayerData('items', inventory)
        ScheduleSave(identifier)
        if ReleaseItemUseReservation then
            -- A successful authoritative consumption ends the slot reservation.
            -- Some QBCore consumables remove by name without a slot, so permit a
            -- same-name removal to release the reservation in that compatibility path.
            if slot ~= nil then
                ReleaseItemUseReservation(identifier, itemName, slot)
            else
                ReleaseItemUseReservation(identifier, itemName)
            end
        end
        if itemName == (Config.CashItemName or 'cash') and Config.CashAsItem then
            local cashTotal = GetItemCount(identifier, Config.CashItemName or 'cash') or 0
            if RSInventorySetCashAccountFromItem then
                RSInventorySetCashAccountFromItem(identifier, cashTotal, 'cash-item-removed')
            else
                player.Functions.SetMoney('cash', cashTotal, 'cash-item-removed-fallback')
            end
        end
        TriggerClientEvent('qb-inventory:client:ItemBox', identifier, itemInfo, 'remove', amount)
        TriggerClientEvent('qb-inventory:client:updateInventory', identifier, player.PlayerData.items)
    elseif inventoryType == 'stash' then
        Inventories[identifier].items = inventory
        ScheduleInventorySave(identifier)
    elseif inventoryType == 'drop' then
        Drops[identifier].items = inventory
    end

    local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier
    local removeReason = reason or 'No reason specified'
    local resourceName = GetInvokingResource() or 'qb-inventory'
    TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'Item Removed', 'red', '**Inventory:** ' .. invName .. ' | **Item:** ' .. item .. ' | **Amount:** ' .. amount .. ' | **Reason:** ' .. removeReason .. ' | **Resource:** ' .. resourceName)
    return true
end
exports('RemoveItem', RemoveItem)

exports('GetPlayerInventoryLimits', function()
    return {
        weight = Config.MaxWeight,
        slots = Config.MaxSlots
    }
end)