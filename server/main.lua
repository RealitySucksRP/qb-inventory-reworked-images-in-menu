---------------------------
-- server/main.lua
---------------------------
QBCore = exports['qb-core']:GetCoreObject()
Inventories = {}
Drops = {}
RegisteredShops = {}
local saveCounters = {}
local activeDropRequests = {}

-- Per-player inventory mutex, shared with cash_sync.lua.
--
-- SetInventoryData (drag/drop moves between inventories) and cash_sync's
-- reconciliation (SetPhysicalCashTotal) both write Player.PlayerData.items
-- directly, and neither knew about the other. createDrop already had its own
-- lock (activeDropRequests) against being called twice for the same player;
-- SetInventoryData had none at all, and cash_sync's direct item-table
-- overwrite (bypassing AddItem/RemoveItem, and any lock those imply) could
-- run at any moment a money-change event fires elsewhere on the server --
-- unrelated to what the player is doing, and deferred via SetTimeout(0), so
-- it can land in the middle of a live drag-and-drop. That is a real window
-- for a cash item to be counted twice: once by the player's own move, once
-- by a reconciliation that read the table before the move committed.
--
-- GLOBAL (no `local`) so cash_sync.lua, in the same resource but a
-- different file, can see and respect it.
RSInventoryBusy = RSInventoryBusy or {}
local completedDropRequests = {}
local lastVendingOpen = {}
local lastUseItem = {}
local lastSnapshotRequest = {}
local lastDropListRequest = {}
local lastMoveRequest = {}
local shopTransactionLocks = {}
local usedItemReservations = {}
local USE_ITEM_RATE_LIMIT = tonumber(Config and Config.UseItemRateLimitMs) or 450
local USE_ITEM_RESERVATION_MS = tonumber(Config and Config.UseItemReservationMs) or 30000

local function GetLiveUseReservation(src)
    src = tonumber(src)
    if not src then return nil end
    local reservation = usedItemReservations[src]
    if not reservation then return nil end
    if GetGameTimer() >= reservation.expiresAt then
        usedItemReservations[src] = nil
        return nil
    end
    return reservation
end

function IsItemUseSlotReserved(src, slot, itemName)
    local reservation = GetLiveUseReservation(src)
    if not reservation then return false end
    slot = tonumber(slot)
    if slot and reservation.slot ~= slot then return false end
    if itemName and tostring(itemName):lower() ~= reservation.name then return false end
    return true
end

function ReleaseItemUseReservation(src, itemName, slot)
    local reservation = GetLiveUseReservation(src)
    if not reservation then return false end
    if itemName and tostring(itemName):lower() ~= reservation.name then return false end
    if slot ~= nil and tonumber(slot) and tonumber(slot) ~= reservation.slot then return false end
    usedItemReservations[tonumber(src)] = nil
    return true
end

local function ReserveItemUse(src, itemData, itemInfo)
    if USE_ITEM_RESERVATION_MS <= 0 or not itemData or not itemInfo then return true end
    if itemInfo.type == 'weapon' or itemInfo.shouldClose == false then return true end
    local slot = tonumber(itemData.slot)
    if not slot or slot < 1 then return false end
    if GetLiveUseReservation(src) then return false end
    usedItemReservations[tonumber(src)] = {
        slot = slot,
        name = tostring(itemData.name):lower(),
        expiresAt = GetGameTimer() + USE_ITEM_RESERVATION_MS,
    }
    return true
end

local function ReservedMoveSlot(inventoryName, actorSrc, slot)
    if type(inventoryName) ~= 'string' then return false end
    local owner = inventoryName == 'player' and tonumber(actorSrc) or
        tonumber(inventoryName:match('^otherplayer%-(%d+)$'))
    if not owner then return false end
    return IsItemUseSlotReserved(owner, slot)
end

local function AcquirePlayerMutationLocks(...)
    local ids, seen = {}, {}
    for i = 1, select('#', ...) do
        local id = tonumber(select(i, ...))
        if id and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)

    for _, id in ipairs(ids) do
        if RSInventoryBusy[id] then return nil end
    end
    for _, id in ipairs(ids) do RSInventoryBusy[id] = true end
    return ids
end

local function ReleasePlayerMutationLocks(ids)
    for _, id in ipairs(ids or {}) do RSInventoryBusy[id] = nil end
end

local function PlayerInventoryActionBlocked(Player)
    if not Player or not Player.PlayerData then return true end
    local metadata = Player.PlayerData.metadata or {}
    return metadata.isdead == true or metadata.inlaststand == true or metadata.ishandcuffed == true
end

local function SameRoutingBucket(sourceA, sourceB)
    if SameInventoryRoutingBucket then return SameInventoryRoutingBucket(sourceA, sourceB) end
    return false
end

local vendingModelHashes = {}
for _, model in ipairs(Config.VendingObjects or {}) do
    vendingModelHashes[joaat(model)] = true
end

local function ValidateVendingInteraction(src, data)
    if type(data) ~= 'table' then return nil, 'vending-no-proof' end

    local model = tonumber(data.model)
    local reportedCoords = NormalizeInventoryCoords(data.coords)
    if not model or not vendingModelHashes[model] then return nil, 'vending-bad-model' end
    if not reportedCoords then return nil, 'vending-bad-coords' end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil, 'vending-no-ped' end
    local playerCoords = GetEntityCoords(ped)
    local maxDistance = tonumber(Config.VendingInteractionDistance) or 3.0
    if #(playerCoords - reportedCoords) > maxDistance then return nil, 'vending-too-far' end

    if Config.VendingStrictLocations == true then
        local matched = false
        for _, location in ipairs(Config.VendingLocations or {}) do
            local anchor = NormalizeInventoryCoords(location)
            if anchor and #(reportedCoords - anchor) <= maxDistance and #(playerCoords - anchor) <= maxDistance then
                reportedCoords = anchor
                matched = true
                break
            end
        end
        if not matched then return nil, 'vending-not-configured' end
    end

    -- Networked objects can be proven server-side. Base-map props often have no
    -- network id; those fall back to model/coords unless strict locations are on.
    local netId = tonumber(data.netId)
    if netId and netId > 0 then
        local entity = NetworkGetEntityFromNetworkId(netId)
        if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, 'vending-entity-missing' end
        if GetEntityType(entity) ~= 3 then return nil, 'vending-not-object' end
        if not vendingModelHashes[GetEntityModel(entity)] then return nil, 'vending-entity-model' end
        local okBucket, entityBucket = pcall(GetEntityRoutingBucket, entity)
        local playerBucket = GetInventoryRoutingBucket(src)
        if not okBucket or playerBucket == nil or tonumber(entityBucket) ~= playerBucket then
            return nil, 'vending-bucket-mismatch'
        end
        local entityCoords = GetEntityCoords(entity)
        if #(playerCoords - entityCoords) > maxDistance then return nil, 'vending-entity-too-far' end
        reportedCoords = entityCoords
    end

    return reportedCoords
end
local SAVE_DELAY = 2500 -- save timer in milliseconds
Config.Debug = false -- Set to false to disable console logs

local function SendRobberyLogToDiscord(title, color, fields)
    local webhook_url = Config.RobberyWebhook
    if type(webhook_url) ~= 'string' or webhook_url == '' then return end
    local embed = {
        {
            ["title"] = title,
            ["color"] = color,
            ["fields"] = fields,
            ["footer"] = {
                ["text"] = "qb-inventory | Robbery Log"
            },
            ["timestamp"] = os.date("!%Y-%m-%dT%H:%M:%S.000Z")
        }
    }
    PerformHttpRequest(webhook_url, function(err, text, headers) end, 'POST', json.encode({ embeds = embed }), { ['Content-Type'] = 'application/json' })
end

local function NormalizePersistedInfo(info)
    if type(info) == 'table' then
        local function clone(value)
            if type(value) ~= 'table' then return value end
            local out = {}
            for key, child in pairs(value) do out[key] = clone(child) end
            return out
        end
        return clone(info)
    end
    if type(info) == 'string' and info ~= '' then
        local ok, decoded = pcall(json.decode, info)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return {}
end

function SanitizeInventory(items, maxSlots)
    if not items or type(items) ~= 'table' then return {}, {} end
    maxSlots = tonumber(maxSlots)
    local sanitizedItems, rejected = {}, {}

    for k, raw in pairs(items) do
        if type(raw) == 'table' then
            local slot = tonumber(raw.slot or k)
            local amount = tonumber(raw.amount or raw.count)
            local name = type(raw.name) == 'string' and raw.name:lower() or nil
            local itemInfo = name and QBCore.Shared.Items[name] or nil
            local validSlot = slot and slot == math.floor(slot) and slot >= 1 and
                                  (not maxSlots or slot <= maxSlots)
            local validAmount = amount and amount == math.floor(amount) and amount > 0

            if validSlot and validAmount and itemInfo and not sanitizedItems[slot] then
                sanitizedItems[slot] = {
                    name = itemInfo.name,
                    amount = amount,
                    info = NormalizePersistedInfo(raw.info),
                    label = itemInfo.label,
                    description = itemInfo.description or '',
                    weight = itemInfo.weight,
                    type = itemInfo.type,
                    unique = itemInfo.unique,
                    useable = itemInfo.useable,
                    image = itemInfo.image,
                    shouldClose = itemInfo.shouldClose,
                    slot = slot,
                    combinable = itemInfo.combinable,
                }
            else
                rejected[#rejected + 1] = name or tostring(raw.name or 'unknown')
            end
        end
    end

    return sanitizedItems, rejected
end

exports('IsCashAsItem', function() return Config.CashAsItem end)
exports('GetCashItemName', function() return Config.CashItemName or 'cash' end)

local function CopyTable(tbl)
    if type(tbl) ~= 'table' then return tbl end
    local newTbl = {}
    for k, v in pairs(tbl) do newTbl[k] = CopyTable(v) end
    return newTbl
end

CreateThread(function()
    MySQL.query('SELECT * FROM inventories', {}, function(result)
        if result and #result > 0 then
            for i = 1, #result do
                local inventory = result[i]
                local cacheKey = inventory.identifier
                local decoded = {}
                if type(inventory.items) == 'string' and inventory.items ~= '' then
                    local ok, parsed = pcall(json.decode, inventory.items)
                    if ok and type(parsed) == 'table' then
                        decoded = parsed
                    else
                        print(('[qb-inventory] Invalid JSON in cached inventory %s; loaded empty instead of crashing the cache loader.'):format(
                            tostring(cacheKey)))
                    end
                end
                -- The preload query is asynchronous. A player may already have
                -- lazy-loaded/opened this same stash while SELECT * was in flight;
                -- never overwrite that newer live cache with the older startup
                -- snapshot when this callback eventually returns.
                if type(cacheKey) == 'string' and cacheKey ~= '' and not Inventories[cacheKey] then
                    Inventories[cacheKey] = {
                        items = SanitizeInventory(decoded),
                        isOpen = false
                    }
                end
            end
            --   print(#result .. ' inventories successfully loaded')
        end
    end)
end)

CreateThread(function()
    while true do
        for k, v in pairs(Drops) do
            if v and (v.createdTime + ((Config.CleanupDropTime or 15) * 60) < os.time()) and
                not Drops[k].isOpen and not Drops[k].carrier then
                TriggerClientEvent('qb-inventory:client:removeDropTarget', -1, v.entityId)
                local entity = NetworkGetEntityFromNetworkId(v.entityId)
                if DoesEntityExist(entity) then DeleteEntity(entity) end
                Drops[k] = nil
            end
        end
        Wait((Config.CleanupDropInterval or 1) * 60000)
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        for _, drop in pairs(Drops) do
            local carrierId = drop and tonumber(drop.carrier) or nil
            if carrierId then
                local CarrierPlayer = QBCore.Functions.GetPlayer(carrierId)
                local ped = CarrierPlayer and GetPlayerPed(carrierId) or 0
                local metadata = CarrierPlayer and CarrierPlayer.PlayerData and CarrierPlayer.PlayerData.metadata or {}
                local down = not CarrierPlayer or metadata.isdead == true or metadata.inlaststand == true
                if not down and ped and ped ~= 0 then
                    local okHealth, health = pcall(GetEntityHealth, ped)
                    down = okHealth and tonumber(health) and health <= 0 or false
                end

                if not CarrierPlayer or not ped or ped == 0 then
                    drop.carrier = nil
                else
                    -- Keep the logical access anchor authoritative while a bag is
                    -- carried. This gives disconnect/death cleanup a recent server
                    -- position even when the client's final release event is lost.
                    drop.coords = GetEntityCoords(ped)
                    local bucket = GetInventoryRoutingBucket(carrierId)
                    if bucket ~= nil and tonumber(drop.bucket) ~= bucket then
                        drop.bucket = bucket
                        local entity = drop.entityId and NetworkGetEntityFromNetworkId(drop.entityId) or 0
                        if entity and entity ~= 0 and DoesEntityExist(entity) then
                            pcall(SetEntityRoutingBucket, entity, bucket)
                        end
                    end
                    if down then drop.carrier = nil end
                end
            end
        end
    end
end)

AddEventHandler('QBCore:Server:PlayerUnloaded', function(source)
    if type(source) == 'table' and source.PlayerData then
        source = source.PlayerData.source
    end
    source = tonumber(source)
    if not source then return end
    CleanupInventorySession(source, true)
    if saveCounters[source] then saveCounters[source] = nil end
    activeDropRequests[source] = nil
    completedDropRequests[source] = nil
    RSInventoryBusy[source] = nil
    lastVendingOpen[source] = nil
    lastUseItem[source] = nil
    lastSnapshotRequest[source] = nil
    lastDropListRequest[source] = nil
    lastMoveRequest[source] = nil
    usedItemReservations[source] = nil
    RegisteredShops['vending-' .. source] = nil
    if PendingRobberies then
        PendingRobberies[source] = nil
        for robberId, pending in pairs(PendingRobberies) do
            if pending.target == source then PendingRobberies[robberId] = nil end
        end
    end

    local ped = GetPlayerPed(source)
    local lastCoords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    for _, drop in pairs(Drops) do
        if drop.carrier == source then
            if lastCoords then drop.coords = lastCoords end
            drop.carrier = nil
        end
    end

    SaveInventory(source)

    for _, inv in pairs(Inventories) do
        if inv.isOpen == source then inv.isOpen = false end
    end
    for _, drop in pairs(Drops) do
        if drop.isOpen == source then drop.isOpen = false end
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    local players = QBCore.Functions.GetPlayers()
    for _, playerId in pairs(players) do SaveInventory(playerId) end
    if FlushDirtyInventories then FlushDirtyInventories() end
end)

RegisterNetEvent('QBCore:Server:UpdateObject', function()
    if source ~= '' then return end
    QBCore = exports['qb-core']:GetCoreObject()
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local src = Player and Player.PlayerData and Player.PlayerData.source
    if src then
        CleanupInventorySession(src, true)
        Player(src).state.inv_busy = false
    end

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'AddItem',
                                     function(item, amount, slot, info, reason)
        return AddItem(Player.PlayerData.source, item, amount, slot, info,
                       reason)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'RemoveItem',
                                     function(item, amount, slot, reason)
        return RemoveItem(Player.PlayerData.source, item, amount, slot, reason)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemBySlot',
                                     function(slot)
        return GetItemBySlot(Player.PlayerData.source, slot)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemByName',
                                     function(item)
        return GetItemByName(Player.PlayerData.source, item)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'GetItemsByName',
                                     function(item)
        return GetItemsByName(Player.PlayerData.source, item)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'ClearInventory',
                                     function(filterItems)
        ClearInventory(Player.PlayerData.source, filterItems)
    end)

    QBCore.Functions.AddPlayerMethod(Player.PlayerData.source, 'SetInventory',
                                     function(items)
        SetInventory(Player.PlayerData.source, items)
    end)

    if Config.CashAsItem and RSInventoryReconcileCashOnLoad then
        SetTimeout(0, function()
            RSInventoryReconcileCashOnLoad(Player.PlayerData.source, 'player-loaded')
        end)
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    local Players = QBCore.Functions.GetPlayers()
    for _, playerId in pairs(Players) do
        ClearInventorySession(playerId)
        QBCore.Functions.AddPlayerMethod(playerId, 'AddItem',
                                         function(item, amount, slot, info)
            return AddItem(playerId, item, amount, slot, info)
        end)

        QBCore.Functions.AddPlayerMethod(playerId, 'RemoveItem', function(item, amount,
                                                                   slot)
            return RemoveItem(playerId, item, amount, slot)
        end)

        QBCore.Functions.AddPlayerMethod(playerId, 'GetItemBySlot', function(slot)
            return GetItemBySlot(playerId, slot)
        end)

        QBCore.Functions.AddPlayerMethod(playerId, 'GetItemByName', function(item)
            return GetItemByName(playerId, item)
        end)

        QBCore.Functions.AddPlayerMethod(playerId, 'GetItemsByName', function(item)
            return GetItemsByName(playerId, item)
        end)

        QBCore.Functions.AddPlayerMethod(playerId, 'ClearInventory', function(
            filterItems) ClearInventory(playerId, filterItems) end)

        QBCore.Functions.AddPlayerMethod(playerId, 'SetInventory', function(items)
            SetInventory(playerId, items)
        end)

        Player(playerId).state.inv_busy = false
    end
end)

local function checkWeapon(source, item)
    local currentWeapon = type(item) == 'table' and item.name or item
    local ped = GetPlayerPed(source)
    local weapon = GetSelectedPedWeapon(ped)
    local weaponInfo = QBCore.Shared.Weapons[weapon]
    if weaponInfo and weaponInfo.name == currentWeapon then
        RemoveWeaponFromPed(ped, weapon)
        TriggerClientEvent('qb-weapons:client:UseWeapon', source,
                           {name = currentWeapon}, false)
    end
end

RegisterNetEvent('qb-inventory:server:openVending', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or PlayerInventoryActionBlocked(Player) then return end
    if IsInventoryServerBusy(src) then return end

    local now = GetGameTimer()
    local lastOpen = lastVendingOpen[src] or 0
    if now - lastOpen < 1000 then return end
    lastVendingOpen[src] = now

    local vendingCoords, reason = ValidateVendingInteraction(src, data)
    if not vendingCoords then
        LogInventoryAccessDenied(src, 'shop-vending-' .. src, reason)
        return
    end

    local shopName = 'vending-' .. src
    CreateShop({
        name = shopName,
        label = 'Vending Machine',
        coords = vendingCoords,
        bucket = GetInventoryRoutingBucket(src),
        slots = #Config.VendingItems,
        items = Config.VendingItems
    })
    TriggerClientEvent('qb-inventory:client:sendServerTime', src, os.time())
    OpenShop(src, shopName)
end)

local function GetItemCountInMap(items)
    if not items then return 0 end
    local count = 0
    for _ in pairs(items) do count = count + 1 end
    return count
end

RegisterNetEvent('qb-inventory:server:closeInventory', function(inventory)
    local src = source
    local QBPlayer = QBCore.Functions.GetPlayer(src)
    if not QBPlayer then return end

    local session = GetInventorySession(src)
    if inventory ~= nil and type(inventory) ~= 'string' then return end
    if type(inventory) == 'string' and #inventory > 255 then return end

    -- An empty name is valid only for the player's own panel. Never reinterpret
    -- an old/empty browser close as "close whatever secondary session exists":
    -- a delayed NUI callback could otherwise tear down a newly opened stash,
    -- trunk, drop or player-search session. Named sessions must close by name.
    local hasNamedInventory = type(inventory) == 'string' and inventory ~= ''
    if not hasNamedInventory then
        if session and session.name ~= 'player' then
            LogInventoryAccessDenied(src, inventory or '', 'close-empty-with-named-session')
            return
        end
        Player(src).state.inv_busy = false
        if session and session.name == 'player' then ClearInventorySession(src) end
        return
    end

    if not session then
        LogInventoryAccessDenied(src, inventory, 'close-no-session')
        return
    end
    if session.name ~= inventory then
        LogInventoryAccessDenied(src, inventory, 'close-session-mismatch')
        return
    end

    Player(src).state.inv_busy = false
    ClearInventorySession(src)

    if inventory:find('^shop%-') then
        if inventory == ('shop-vending-' .. src) then
            RegisteredShops['vending-' .. src] = nil
        end
        return
    end

    if inventory:find('^otherplayer%-') then
        local targetId = tonumber(inventory:match('^otherplayer%-(%d+)$'))
        if targetId and QBCore.Functions.GetPlayer(targetId) then
            Player(targetId).state.inv_busy = false
        end
        return
    end

    if Drops[inventory] then
        if Drops[inventory].isOpen and Drops[inventory].isOpen ~= src then
            LogInventoryAccessDenied(src, inventory, 'close-drop-not-owner')
            return
        end
        Drops[inventory].isOpen = false
        if GetItemCountInMap(Drops[inventory].items) == 0 then
            if Config.Debug then
                print(('[INV_DEBUG_SERVER] Drop bag %s is empty, deleting.'):format(inventory))
            end
            local entityId = Drops[inventory].entityId
            -- Remove the logical inventory first so a forged openDrop cannot
            -- re-open an empty bag during an entity-deletion delay/window.
            Drops[inventory] = nil
            TriggerClientEvent('qb-inventory:client:removeDropTarget', -1, entityId)
            local entity = NetworkGetEntityFromNetworkId(entityId)
            if entity and entity ~= 0 and DoesEntityExist(entity) then DeleteEntity(entity) end
        elseif Config.Debug then
            print(('[INV_DEBUG_SERVER] Drop bag %s is not empty (%s items), keeping it.'):format(
                inventory, GetItemCountInMap(Drops[inventory].items)))
        end
        return
    end

    if not Inventories[inventory] then return end
    if Inventories[inventory].isOpen and Inventories[inventory].isOpen ~= src then
        LogInventoryAccessDenied(src, inventory, 'close-stash-not-owner')
        return
    end
    Inventories[inventory].isOpen = false
    if SaveStashInventory then
        CreateThread(function() SaveStashInventory(inventory) end)
    end
end)

RegisterNetEvent('qb-inventory:server:useItem', function(item)
    local src = source
    if type(item) ~= 'table' then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or PlayerInventoryActionBlocked(Player) then return end
    local now = GetGameTimer()
    if lastUseItem[src] and (now - lastUseItem[src]) < USE_ITEM_RATE_LIMIT then return end
    lastUseItem[src] = now

    local slot = tonumber(item.slot)
    if not slot or slot ~= math.floor(slot) or slot < 1 or slot > Config.MaxSlots then
        return
    end

    local itemData = GetItemBySlot(src, slot)
    if not itemData then return end
    if itemData.name == (Config.CashItemName or 'cash') then return end

    local itemInfo = QBCore.Shared.Items[itemData.name]
    if not itemInfo then return end
    local itemMeta = type(itemData.info) == 'table' and itemData.info or {}

    if IsItemUseSlotReserved(src, slot) then return end

    if itemMeta.expiryDate and os.time() >= itemMeta.expiryDate then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.item_expired'),
                           'error')
        return
    end

    -- Reserve delayed-use slots against drag/give/drop races. External usable
    -- item callbacks may consume immediately or only after a client progress bar;
    -- RemoveItem releases this early when the authoritative consumption commits.
    if not ReserveItemUse(src, itemData, itemInfo) then return end

    if itemData.type == 'weapon' then
        TriggerClientEvent('qb-weapons:client:UseWeapon', src, itemData,
                           itemMeta.quality and itemMeta.quality > 0)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
    elseif itemData.name == 'id_card' then
        UseItem(itemData.name, src, itemData)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local players = QBCore.Functions.GetPlayers()
        local gender = itemMeta.gender == 0 and 'Male' or 'Female'
        for _, v in pairs(players) do
            local targetPed = GetPlayerPed(v)
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist < 3.0 then
                TriggerClientEvent('chat:addMessage', v, {
                    template = '<div class="chat-message advert" style="background: linear-gradient(to right, rgba(5, 5, 5, 0.6), #74807c); display: flex;"><div style="margin-right: 10px;"><i class="far fa-id-card" style="height: 100%;"></i><strong> {0}</strong><br> <strong>Civ ID:</strong> {1} <br><strong>First Name:</strong> {2} <br><strong>Last Name:</strong> {3} <br><strong>Birthdate:</strong> {4} <br><strong>Gender:</strong> {5} <br><strong>Nationality:</strong> {6}</div></div>',
                    args = {
                        'ID Card', itemMeta.citizenid, itemMeta.firstname,
                        itemMeta.lastname, itemMeta.birthdate, gender,
                        itemMeta.nationality
                    }
                })
            end
        end
    elseif itemData.name == 'driver_license' then
        UseItem(itemData.name, src, itemData)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
        local playerPed = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(playerPed)
        local players = QBCore.Functions.GetPlayers()
        for _, v in pairs(players) do
            local targetPed = GetPlayerPed(v)
            local dist = #(playerCoords - GetEntityCoords(targetPed))
            if dist < 3.0 then
                TriggerClientEvent('chat:addMessage', v, {
                    template = '<div class="chat-message advert" style="background: linear-gradient(to right, rgba(5, 5, 5, 0.6), #657175); display: flex;"><div style="margin-right: 10px;"><i class="far fa-id-card" style="height: 100%;"></i><strong> {0}</strong><br> <strong>First Name:</strong> {1} <br><strong>Last Name:</strong> {2} <br><strong>Birth Date:</strong> {3} <br><strong>Licenses:</strong> {4}</div></div>',
                    args = {
                        'Drivers License', itemMeta.firstname,
                        itemMeta.lastname, itemMeta.birthdate, itemMeta.type
                    }
                })
            end
        end
    else
        UseItem(itemData.name, src, itemData)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, itemInfo, 'use')
    end
end)

RegisterNetEvent('qb-inventory:server:openDrop', function(dropId)
    local src = source
    if type(dropId) ~= 'string' or #dropId > 96 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or PlayerInventoryActionBlocked(Player) or IsInventoryServerBusy(src) then return end

    local drop = Drops[dropId]
    if not drop or drop.isOpen or drop.carrier then return end
    local bucket = GetInventoryRoutingBucket(src)
    if bucket == nil or drop.bucket == nil or tonumber(drop.bucket) ~= bucket then return end

    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local dropCoords = NormalizeInventoryCoords(drop.coords)
    if not dropCoords or #(playerCoords - dropCoords) > (tonumber(Config.DropAccessDistance) or 3.5) then return end

    local formattedInventory = {
        name = dropId,
        label = dropId,
        maxweight = drop.maxweight,
        slots = drop.slots,
        inventory = drop.items
    }
    if not SetInventorySession(src, dropId, 'drop', { bucket = drop.bucket, anchor = dropCoords }) then return end
    drop.isOpen = src
    Player(src).state.inv_busy = true
    TriggerClientEvent('qb-inventory:client:sendServerTime', src, os.time())
    TriggerClientEvent('qb-inventory:client:openInventory', src,
                       Player.PlayerData.items, formattedInventory)
end)

-- Picking a bag up used to be purely client side, so the server had no idea who
-- was carrying what. `updateDrop` then took any drop id and any coords from any
-- client, which let a player teleport every bag on the map to their own feet
-- (and threw "attempt to index a nil value" on an unknown id). Pickup is now
-- server-validated and records a carrier, and updateDrop only honours a move
-- from the player who actually holds that bag.
QBCore.Functions.CreateCallback('qb-inventory:server:pickupDrop',
                                function(source, cb, dropId)
    local src = source
    if type(dropId) ~= 'string' then
        cb(false)
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    local drop = Drops[dropId]
    if not Player or not drop or PlayerInventoryActionBlocked(Player) then
        cb(false)
        return
    end
    if IsInventoryServerBusy(src) then
        cb(false)
        return
    end
    local bucket = GetInventoryRoutingBucket(src)
    if bucket == nil or drop.bucket == nil or tonumber(drop.bucket) ~= bucket then
        cb(false)
        return
    end

    -- Recover stale carriers server-side. A dead/disconnected carrier may never
    -- get a chance to send the normal client release event; without this, one
    -- missed cleanup permanently bricks the bag for everyone else.
    if drop.carrier and drop.carrier ~= src then
        local carrierId = tonumber(drop.carrier)
        local CarrierPlayer = carrierId and QBCore.Functions.GetPlayer(carrierId) or nil
        local metadata = CarrierPlayer and CarrierPlayer.PlayerData and CarrierPlayer.PlayerData.metadata or nil
        local carrierDown = not CarrierPlayer or (metadata and (metadata.isdead or metadata.inlaststand))
        if carrierDown then
            if CarrierPlayer then
                local carrierPed = GetPlayerPed(carrierId)
                if carrierPed and carrierPed ~= 0 then drop.coords = GetEntityCoords(carrierPed) end
            end
            drop.carrier = nil
        else
            cb(false)
            return
        end
    end

    if drop.isOpen or drop.carrier then
        cb(false)
        return
    end

    local dropCoords = NormalizeInventoryCoords(drop.coords)
    if not dropCoords then
        cb(false)
        return
    end

    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - dropCoords) > 3.0 then
        cb(false)
        return
    end

    -- One player may carry exactly one server-tracked bag. Silently releasing
    -- an older carrier left that physical bag attached client-side.
    for existingId, existing in pairs(Drops) do
        if existingId ~= dropId and existing.carrier == src then
            LogInventoryAccessDenied(src, dropId, 'drop-already-carrying')
            cb(false)
            return
        end
    end

    drop.carrier = src
    cb(true)
end)

RegisterNetEvent('qb-inventory:server:updateDrop', function(dropId, coords)
    local src = source

    if type(dropId) ~= 'string' or #dropId > 96 then
        LogInventoryAccessDenied(src, '<invalid-drop-id>', 'drop-bad-id')
        return
    end

    local drop = Drops[dropId]
    if not drop then
        LogInventoryAccessDenied(src, dropId, 'drop-unknown')
        return
    end

    if drop.carrier ~= src then
        LogInventoryAccessDenied(src, dropId, 'drop-not-carrier')
        return
    end

    local bucket = GetInventoryRoutingBucket(src)
    if bucket == nil or drop.bucket == nil or tonumber(drop.bucket) ~= bucket then
        LogInventoryAccessDenied(src, dropId, 'drop-bucket-mismatch')
        drop.carrier = nil
        return
    end

    local playerPed = GetPlayerPed(src)
    if not playerPed or playerPed == 0 then return end
    local playerCoords = GetEntityCoords(playerPed)

    -- The visible bag is moved by its current network owner, but the access
    -- anchor comes from the carrier's server position, not arbitrary event data.
    local reported = NormalizeInventoryCoords(coords)
    if reported and #(playerCoords - reported) > 5.0 then
        LogInventoryAccessDenied(src, dropId, 'drop-coords-mismatch')
    end

    drop.coords = playerCoords
    drop.carrier = nil
end)

QBCore.Functions.CreateCallback('qb-inventory:server:GetCurrentDrops',
                                function(source, cb)
    local now = GetGameTimer()
    local interval = tonumber(Config.DropListRateLimitMs) or 1000
    if lastDropListRequest[source] and (now - lastDropListRequest[source]) < interval then
        cb(false)
        return
    end
    lastDropListRequest[source] = now

    -- Only opaque network ids are exposed here, never item contents/coords. Keep
    -- references for every live drop so a client that later changes routing
    -- buckets can attach qb-target when that entity actually streams into scope.
    -- Open/pickup/update remain bucket- and distance-authorized server-side.
    local publicDrops = {}
    for dropName, drop in pairs(Drops) do
        if drop and drop.entityId then publicDrops[dropName] = { entityId = drop.entityId } end
    end
    cb(publicDrops)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:createDrop',
                                function(source, cb, item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or PlayerInventoryActionBlocked(Player) or type(item) ~= 'table' then
        cb(false)
        return
    end

    local operationId = tostring(item.operationId or '')
    if #operationId > 96 then
        cb(false)
        return
    end
    completedDropRequests[src] = completedDropRequests[src] or {}

    if operationId ~= '' and completedDropRequests[src][operationId] then
        cb(CopyTable(completedDropRequests[src][operationId]))
        return
    end

    if activeDropRequests[src] then
        cb(false)
        return
    end
    -- Also block on the shared inventory mutex: this creates a new item
    -- (removed from the player, moved into a fresh Drop) and must not overlap
    -- with a concurrent SetInventoryData move or a cash-item reconciliation
    -- touching the same player's item table.
    if RSInventoryBusy[src] then
        cb(false)
        return
    end
    activeDropRequests[src] = true
    RSInventoryBusy[src] = true

    local function finish(response)
        activeDropRequests[src] = nil
        RSInventoryBusy[src] = nil

        if response and operationId ~= '' then
            completedDropRequests[src][operationId] = CopyTable(response)
            SetTimeout(10000, function()
                if completedDropRequests[src] then
                    completedDropRequests[src][operationId] = nil
                    if not next(completedDropRequests[src]) then
                        completedDropRequests[src] = nil
                    end
                end
            end)
        end

        cb(response)
    end

    local fromSlot = tonumber(item.fromSlot)
    local amountToDrop = math.floor(tonumber(item.amount) or 0)

    if not fromSlot or amountToDrop <= 0 then
        finish(false)
        return
    end

    local itemOnServer = Player.PlayerData.items[fromSlot]
    if IsItemUseSlotReserved(src, fromSlot) then
        finish(false)
        return
    end
    if not itemOnServer then
        finish(false)
        return
    end

    local requestedName = tostring(item.name or ''):lower()
    if itemOnServer.name ~= requestedName or amountToDrop > itemOnServer.amount then
        finish(false)
        return
    end

    local originalItem = CopyTable(itemOnServer)

    -- Keep the current session intact until the replacement drop is fully
    -- created. SetInventorySession performs the old-lock release atomically on
    -- the successful transition; failures below therefore leave the old UI valid.
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local dropBucket = GetInventoryRoutingBucket(src)
    if dropBucket == nil then
        finish(false)
        return
    end

    if not RemoveItem(src, itemOnServer.name, amountToDrop, fromSlot, 'dropped item') then
        finish(false)
        return
    end

    if originalItem.type == 'weapon' then checkWeapon(src, originalItem) end
    TaskPlayAnim(playerPed, 'pickup_object', 'pickup_low', 8.0, -8.0, 2000,
                 0, 0, false, false, false)

    local bag = CreateObjectNoOffset(Config.ItemDropObject,
                                     playerCoords.x + 0.5,
                                     playerCoords.y + 0.5,
                                     playerCoords.z,
                                     true, true, false)

    if not bag or bag == 0 or not DoesEntityExist(bag) then
        AddItem(src, originalItem.name, amountToDrop, fromSlot,
                originalItem.info, 'drop-create-failed-refund')
        finish(false)
        return
    end

    pcall(SetEntityRoutingBucket, bag, dropBucket)
    pcall(SetEntityOrphanMode, bag, 2)

    local dropId = NetworkGetNetworkIdFromEntity(bag)
    if not dropId or dropId == 0 then
        DeleteEntity(bag)
        AddItem(src, originalItem.name, amountToDrop, fromSlot,
                originalItem.info, 'drop-network-failed-refund')
        finish(false)
        return
    end

    local newDropId = 'drop-' .. dropId
    local newItemForDrop = CopyTable(originalItem)
    newItemForDrop.amount = amountToDrop
    newItemForDrop.slot = 1

    if Drops[newDropId] then
        DeleteEntity(bag)
        AddItem(src, originalItem.name, amountToDrop, fromSlot,
                originalItem.info, 'drop-id-collision-refund')
        finish(false)
        return
    else
        Drops[newDropId] = {
            name = newDropId,
            label = 'Drop',
            items = {[1] = newItemForDrop},
            entityId = dropId,
            createdTime = os.time(),
            coords = playerCoords,
            bucket = dropBucket,
            carrier = nil,
            maxweight = Config.DropSize.maxweight,
            slots = Config.DropSize.slots,
            isOpen = false
        }
    end

    if not SetInventorySession(src, newDropId, 'drop', { bucket = dropBucket, anchor = playerCoords }) then
        Drops[newDropId] = nil
        DeleteEntity(bag)
        AddItem(src, originalItem.name, amountToDrop, fromSlot,
                originalItem.info, 'drop-session-failed-refund')
        finish(false)
        return
    end
    Drops[newDropId].isOpen = src
    TriggerClientEvent('qb-inventory:client:setupDropTarget', -1, dropId)

    local responseData = {
        netId = dropId,
        dropData = {
            name = newDropId,
            label = 'Drop',
            maxweight = Config.DropSize.maxweight,
            slots = Config.DropSize.slots,
            inventory = CopyTable(Drops[newDropId].items)
        },
        playerInventory = CopyTable(Player.PlayerData.items)
    }

    finish(responseData)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:attemptPurchase',
                                function(source, cb, data)
    if type(data) ~= 'table' or type(data.shop) ~= 'string' or
        type(data.item) ~= 'table' then
        cb(false)
        return
    end

    local amount = tonumber(data.amount)
    local slot = tonumber(data.item.slot)
    if not amount or amount ~= math.floor(amount) or amount <= 0 or
        not slot or slot ~= math.floor(slot) or slot <= 0 then
        cb(false)
        return
    end

    local shopInventoryName = data.shop
    if shopInventoryName:find('^shop%-') ~= 1 then
        cb(false)
        return
    end

    local allowed, reason = CanAccessInventory(source, shopInventoryName)
    if not allowed then
        LogInventoryAccessDenied(source, shopInventoryName,
                                 'purchase-' .. tostring(reason))
        cb(false)
        return
    end

    local shop = shopInventoryName:gsub('^shop%-', '')
    local Player = QBCore.Functions.GetPlayer(source)
    local shopInfo = RegisteredShops[shop]
    if not Player or PlayerInventoryActionBlocked(Player) or not shopInfo then
        cb(false)
        return
    end

    local shopItem = shopInfo.items[slot]
    if not shopItem or type(shopItem.name) ~= 'string' then
        cb(false)
        return
    end

    local stock = tonumber(shopItem.amount) or 0
    if amount > stock then
        TriggerClientEvent('QBCore:Notify', source,
                           'Cannot purchase larger quantity than currently in stock',
                           'error')
        cb(false)
        return
    end

    if not CanAddItem(source, shopItem.name, amount) then
        TriggerClientEvent('QBCore:Notify', source, 'Cannot hold item', 'error')
        cb(false)
        return
    end

    local unitPrice = tonumber(shopItem.price)
    if not unitPrice or unitPrice < 0 then
        cb(false)
        return
    end
    local price = unitPrice * amount

    -- A purchase mutates two shared resources: the buyer inventory/cash and the
    -- specific shop slot. The old per-player lock protected only the buyer, so
    -- two different players could both read the same final stock and oversell it.
    local shopLockKey = ('%s:%s'):format(shop, slot)
    if shopTransactionLocks[shopLockKey] then
        cb(false)
        return
    end
    local playerLocks = AcquirePlayerMutationLocks(source)
    if not playerLocks then
        cb(false)
        return
    end
    shopTransactionLocks[shopLockKey] = source

    local paidAmount = 0
    local itemAdded = false
    local ok, purchaseResult = pcall(function()
        -- Re-read stock after acquiring the mutation lock so this callback never
        -- commits against a stale pre-lock quantity.
        local currentStock = tonumber(shopItem.amount) or 0
        if amount > currentStock then
            TriggerClientEvent('QBCore:Notify', source,
                               'Cannot purchase larger quantity than currently in stock',
                               'error')
            return false
        end

        local canPay = price == 0 or RemoveCash(source, price, 'shop-purchase')
        if not canPay then
            TriggerClientEvent('QBCore:Notify', source,
                               'You do not have enough money', 'error')
            return false
        end
        paidAmount = price

        -- Price, item identity and metadata all come from the registered
        -- server-side shop entry; the browser is not authoritative here.
        local purchaseInfo = CopyTable(shopItem.info or {})
        if not AddItem(source, shopItem.name, amount, nil, purchaseInfo,
                       'shop-purchase') then
            if price > 0 then AddCash(source, price, 'shop-purchase-failed-refund') end
            paidAmount = 0
            TriggerClientEvent('QBCore:Notify', source,
                               'Transaction failed, could not add item.', 'error')
            return false
        end

        itemAdded = true
        shopItem.amount = currentStock - amount
        TriggerEvent('qb-shops:server:UpdateShopItems', shop, shopItem, amount)
        TriggerClientEvent('qb-inventory:client:updateInventory', source,
                           Player.PlayerData.items)
        return true
    end)

    -- Never strand the per-player mutation lock on an unexpected integration
    -- exception. If payment happened but the item was not granted, refund it.
    shopTransactionLocks[shopLockKey] = nil
    ReleasePlayerMutationLocks(playerLocks)
    if not ok then
        if paidAmount > 0 and not itemAdded then
            pcall(AddCash, source, paidAmount, 'shop-purchase-error-refund')
        end
        local line = ('[qb-inventory] shop purchase error src=%s shop=%s slot=%s: %s')
            :format(tostring(source), tostring(shop), tostring(slot), tostring(purchaseResult))
        print('^1' .. line .. '^7')
        TriggerEvent('qb-log:server:CreateLog', 'playerinventory', 'Shop purchase error',
                     'red', line, false)
        cb(false)
        return
    end

    cb(purchaseResult == true)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:giveItem',
                                function(source, cb, data, legacyItemName, legacyAmount, legacySlot, legacyInfo)
    -- Accept both qb-inventory-rework payloads and older custom UI callback
    -- arguments, but never trust the browser for item identity or metadata.
    if type(data) ~= 'table' then
        data = {
            targetId = data,
            amount = legacyAmount,
            slot = legacySlot,
        }
    end

    local player = QBCore.Functions.GetPlayer(source)
    local targetId = tonumber(data.targetId)
    local Target = QBCore.Functions.GetPlayer(targetId)

    if not player or not targetId or targetId == source or
        player.PlayerData.metadata['isdead'] or
        player.PlayerData.metadata['inlaststand'] or
        player.PlayerData.metadata['ishandcuffed'] then
        cb(false)
        return
    end

    if not Target or Target.PlayerData.metadata['isdead'] or
        Target.PlayerData.metadata['inlaststand'] or
        Target.PlayerData.metadata['ishandcuffed'] then
        cb(false)
        return
    end

    if not SameRoutingBucket(source, targetId) then
        cb(false)
        return
    end

    local pCoords = GetEntityCoords(GetPlayerPed(source))
    local tCoords = GetEntityCoords(GetPlayerPed(targetId))
    if #(pCoords - tCoords) > (tonumber(Config.PlayerAccessDistance) or 3.5) then
        cb(false)
        return
    end

    local amount = tonumber(data.amount)
    local slot = tonumber(data.slot)
    if not amount or amount ~= math.floor(amount) or amount <= 0 or
        not slot or slot ~= math.floor(slot) or slot < 1 or slot > Config.MaxSlots then
        cb(false)
        return
    end

    -- Giving is one transaction across two live player tables. Lock both players
    -- so the receiver cannot move/use items (or run a cash reconciliation) in
    -- the middle of the remove/add/rollback sequence.
    local playerLocks = AcquirePlayerMutationLocks(source, targetId)
    if not playerLocks then
        cb(false)
        return
    end

    local ok, result = pcall(function()
        -- Re-read all mutable state after the locks are held.
        player = QBCore.Functions.GetPlayer(source)
        Target = QBCore.Functions.GetPlayer(targetId)
        if not player or not Target or PlayerInventoryActionBlocked(player) or
            PlayerInventoryActionBlocked(Target) or not SameRoutingBucket(source, targetId) then
            return false
        end

        local sourcePed = GetPlayerPed(source)
        local targetPed = GetPlayerPed(targetId)
        if sourcePed == 0 or targetPed == 0 or
            #(GetEntityCoords(sourcePed) - GetEntityCoords(targetPed)) >
                (tonumber(Config.PlayerAccessDistance) or 3.5) then
            return false
        end

        local serverItem = player.PlayerData.items and player.PlayerData.items[slot]
        if IsItemUseSlotReserved(source, slot) then return false end
        if not serverItem or type(serverItem.name) ~= 'string' or
            amount > (tonumber(serverItem.amount) or 0) then
            return false
        end

        local item = serverItem.name:lower()
        local itemInfo = QBCore.Shared.Items[item]
        if not itemInfo then return false end
        local info = CopyTable(serverItem.info or {})

        if not RemoveItem(source, item, amount, slot, 'Item given to ID #' .. targetId) then
            return false
        end
        if not AddItem(targetId, item, amount, false, info, 'Item received from ID #' .. source) then
            if not AddItem(source, item, amount, slot, info, 'Failed to give item, returned.') then
                print(('[qb-inventory] CRITICAL: give rollback failed source=%s target=%s item=%s amount=%s')
                    :format(source, targetId, item, amount))
            end
            return false
        end

        if itemInfo.type == 'weapon' then checkWeapon(source, item) end
        TriggerClientEvent('qb-inventory:client:giveAnim', source)
        TriggerClientEvent('qb-inventory:client:giveAnim', targetId)
        if IsInventoryServerBusy(targetId) then
            TriggerClientEvent('qb-inventory:client:updateInventory', targetId, Target.PlayerData.items)
        end
        return true
    end)

    ReleasePlayerMutationLocks(playerLocks)
    if not ok then
        print(('[qb-inventory] giveItem transaction error source=%s target=%s: %s')
            :format(tostring(source), tostring(targetId), tostring(result)))
        cb(false)
        return
    end
    cb(result == true)
end)

local function getItem(inventoryId, src, slot)
    local items = {}
    if inventoryId == 'player' then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData.items then
            items = Player.PlayerData.items
        end
    elseif inventoryId:find('^otherplayer%-') then
        local targetId = tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
        local targetPlayer = QBCore.Functions.GetPlayer(targetId)
        if targetPlayer and targetPlayer.PlayerData.items then
            items = targetPlayer.PlayerData.items
        end
    elseif inventoryId:find('drop-') == 1 then
        if Drops[inventoryId] and Drops[inventoryId]['items'] then
            items = Drops[inventoryId]['items']
        end
    else
        if Inventories[inventoryId] and Inventories[inventoryId]['items'] then
            items = Inventories[inventoryId]['items']
        end
    end

    for _, item in pairs(items) do if item.slot == slot then return item end end
    return nil
end

local function getIdentifier(inventoryId, src)
    if inventoryId == 'player' then
        return src
    elseif inventoryId:find('^otherplayer%-') then
        return tonumber(inventoryId:match('^otherplayer%-(%d+)$'))
    else
        return inventoryId
    end
end


local function GetInventoryWeightState(identifier)
    local Player = QBCore.Functions.GetPlayer(identifier)
    if Player then
        return Player.PlayerData.items or {}, tonumber(Config.MaxWeight) or 0
    end

    local inventory = Inventories[identifier] or Drops[identifier]
    if inventory then
        return inventory.items or {}, tonumber(inventory.maxweight) or 0
    end
    return nil, nil
end

local function CanReceiveFullSwap(identifier, outgoingItem, incomingItem)
    local items, maxWeight = GetInventoryWeightState(identifier)
    if not items or not maxWeight or maxWeight <= 0 then return false, 'inventory' end

    local outgoingDef = outgoingItem and QBCore.Shared.Items[outgoingItem.name]
    local incomingDef = incomingItem and QBCore.Shared.Items[incomingItem.name]
    if not outgoingDef or not incomingDef then return false, 'item' end

    local outgoingAmount = tonumber(outgoingItem.amount) or 0
    local incomingAmount = tonumber(incomingItem.amount) or 0
    local outgoingWeight = (tonumber(outgoingDef.weight) or 0) * outgoingAmount
    local incomingWeight = (tonumber(incomingDef.weight) or 0) * incomingAmount
    local projectedWeight = GetTotalWeight(items) - outgoingWeight + incomingWeight
    if projectedWeight > maxWeight then return false, 'weight' end
    return true
end


local function BuildOtherInventorySnapshot(inventoryName)
    if type(inventoryName) ~= 'string' or inventoryName == '' or
        inventoryName == 'player' then
        return nil
    end

    if inventoryName:find('^otherplayer%-') then
        local targetId = tonumber(inventoryName:match('^otherplayer%-(%d+)$'))
        local TargetPlayer = targetId and QBCore.Functions.GetPlayer(targetId)
        if not TargetPlayer then return nil end
        return {
            name = inventoryName,
            label = GetPlayerName(targetId) or inventoryName,
            maxweight = Config.MaxWeight,
            slots = Config.MaxSlots,
            inventory = CopyTable(TargetPlayer.PlayerData.items or {})
        }
    end

    if inventoryName:find('shop%-') == 1 then
        local shopName = inventoryName:gsub('^shop%-', '')
        local shop = RegisteredShops[shopName]
        if not shop then return nil end
        return {
            name = inventoryName,
            label = shop.label or shopName,
            maxweight = 5000000,
            slots = shop.slots or #(shop.items or {}),
            inventory = CopyTable(shop.items or {})
        }
    end

    local drop = Drops[inventoryName]
    if drop then
        return {
            name = inventoryName,
            label = drop.label or 'Drop',
            maxweight = drop.maxweight or Config.DropSize.maxweight,
            slots = drop.slots or Config.DropSize.slots,
            inventory = CopyTable(drop.items or {})
        }
    end

    local inventory = Inventories[inventoryName]
    if inventory then
        return {
            name = inventoryName,
            label = inventory.label or inventoryName,
            maxweight = inventory.maxweight or Config.StashSize.maxweight,
            slots = inventory.slots or Config.StashSize.slots,
            inventory = CopyTable(inventory.items or {})
        }
    end

    return nil
end

local function BuildInventorySnapshot(src, otherInventoryName, operationOk, operationError)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end

    return {
        ok = operationOk ~= false,
        error = operationError,
        playerInventory = CopyTable(Player.PlayerData.items or {}),
        other = BuildOtherInventorySnapshot(otherInventoryName)
    }
end

QBCore.Functions.CreateCallback('qb-inventory:server:getInventorySnapshot',
                                function(source, cb, otherInventoryName)
    local now = GetGameTimer()
    local interval = tonumber(Config.SnapshotRateLimitMs) or 100
    if lastSnapshotRequest[source] and (now - lastSnapshotRequest[source]) < interval then
        cb(false)
        return
    end
    lastSnapshotRequest[source] = now

    if otherInventoryName ~= nil then
        if type(otherInventoryName) ~= 'string' or #otherInventoryName > 255 then
            cb(false)
            return
        end
        local allowed, reason = CanAccessInventory(source, otherInventoryName)
        if not allowed then
            LogInventoryAccessDenied(source, otherInventoryName,
                                     'snapshot-' .. tostring(reason))
            cb(false)
            return
        end
    end

    cb(BuildInventorySnapshot(source, otherInventoryName, true))
end)

RegisterNetEvent('qb-inventory:server:SetInventoryData',
                 function(fromInventory, toInventory, fromSlot, toSlot,
                          fromAmount, toAmount, requestId)
    local src = source
    local actingPlayer = QBCore.Functions.GetPlayer(src)
    if not actingPlayer or PlayerInventoryActionBlocked(actingPlayer) then
        if requestId and actingPlayer and type(requestId) == 'string' and #requestId <= 96 then
            TriggerClientEvent('qb-inventory:client:inventoryOperationResult', src,
                               requestId, BuildInventorySnapshot(src, nil, false,
                               'player-state-blocked'))
        end
        return
    end

    if requestId ~= nil and (type(requestId) ~= 'string' or #requestId > 96) then return end
    if type(fromInventory) ~= 'string' or type(toInventory) ~= 'string' or
        #fromInventory > 255 or #toInventory > 255 then return end

    local now = GetGameTimer()
    local moveInterval = tonumber(Config.MoveRateLimitMs) or 50
    if lastMoveRequest[src] and (now - lastMoveRequest[src]) < moveInterval then return end
    lastMoveRequest[src] = now

    -- Reject a second move for this player while one is still in flight. The
    -- client already guards this with inventoryActionPending, but that is a UI
    -- nicety a lagged/duplicate network request or a modified client can bypass
    -- outright; this is the actual backstop. Also shared with cash_sync.lua,
    -- so a cash-item reconciliation triggered by an unrelated money change
    -- cannot land in the middle of this player's own drag-and-drop.
    if RSInventoryBusy[src] then return end
    RSInventoryBusy[src] = true

    local otherInventoryName
    local robberyTargetId
    local robberyItemName
    local robberyAmount
    local moveCompleted = false
    local secondaryPlayerLock

    if type(fromInventory) == 'string' and fromInventory ~= 'player' then
        otherInventoryName = fromInventory
    end
    if type(toInventory) == 'string' and toInventory ~= 'player' then
        otherInventoryName = toInventory
    end

    local ok, err = pcall(function()
            if Config.Debug then
                print(('[INV_DEBUG_SERVER] SetInventoryData Received from source: %s'):format(src))
                print(('[INV_DEBUG_SERVER] > fromInventory: %s | toInventory: %s'):format(tostring(fromInventory), tostring(toInventory)))
                print(('[INV_DEBUG_SERVER] > fromSlot: %s | toSlot: %s'):format(tostring(fromSlot), tostring(toSlot)))
                print(('[INV_DEBUG_SERVER] > fromAmount (original amount): %s | toAmount (amount moved): %s'):format(tostring(fromAmount), tostring(toAmount)))
            end

            if toAmount == nil or tonumber(toAmount) <= 0 then
                if Config.Debug then
                    print(('[INV_DEBUG_SERVER] ERROR: Received invalid or zero toAmount (%s). Aborting move.'):format(tostring(toAmount)))
                end
                return
            end

            local function table_copy(orig)
                local orig_type = type(orig)
                local copy
                if orig_type == 'table' then
                    copy = {}
                    for orig_key, orig_value in pairs(orig) do
                        copy[orig_key] = orig_value
                    end
                else
                    copy = orig
                end
                return copy
            end

            if type(fromInventory) ~= 'string' or type(toInventory) ~= 'string' or
                not fromSlot or not toSlot or not fromAmount or not toAmount then
                return
            end
            if toInventory:find('^shop%-') then return end

            local Player = QBCore.Functions.GetPlayer(src)
            if not Player then return end

            fromSlot, toSlot, fromAmount, toAmount = tonumber(fromSlot),
                                                     tonumber(toSlot),
                                                     tonumber(fromAmount),
                                                     tonumber(toAmount)

            -- Access control. Everything below this point reads and writes real
            -- inventories, so the caller has to prove they may touch both ends of
            -- the move before getItem() is allowed to resolve anything.
            --
            -- Without this a single client event drained any online player, any
            -- drop or any cached stash:
            --     TriggerServerEvent('qb-inventory:server:SetInventoryData',
            --                        'otherplayer-7', 'player', 1, 1, 999, 999, 'x')
            if not IsValidMoveAmount(toAmount) then
                LogInventoryAccessDenied(src, toInventory, 'bad-amount')
                return
            end

            if not IsValidSlot(fromSlot, GetInventorySlotCount(fromInventory)) then
                LogInventoryAccessDenied(src, fromInventory, 'bad-from-slot')
                return
            end

            if not IsValidSlot(toSlot, GetInventorySlotCount(toInventory)) then
                LogInventoryAccessDenied(src, toInventory, 'bad-to-slot')
                return
            end

            if ReservedMoveSlot(fromInventory, src, fromSlot) or
                ReservedMoveSlot(toInventory, src, toSlot) then
                LogInventoryAccessDenied(src, fromInventory, 'item-use-slot-reserved')
                return
            end

            local canFrom, fromReason = CanAccessInventory(src, fromInventory)
            if not canFrom then
                LogInventoryAccessDenied(src, fromInventory, fromReason)
                return
            end

            local canTo, toReason = CanAccessInventory(src, toInventory)
            if not canTo then
                LogInventoryAccessDenied(src, toInventory, toReason)
                return
            end

            -- A robbery/admin move touches the victim's live player table too.
            -- Lock that player for the entire transaction so their own NUI/cash
            -- sync/give operation cannot interleave with our rollback sequence.
            local targetFrom = tonumber(fromInventory:match('^otherplayer%-(%d+)$'))
            local targetTo = tonumber(toInventory:match('^otherplayer%-(%d+)$'))
            local otherPlayerId = targetFrom or targetTo
            if targetFrom and targetTo and targetFrom ~= targetTo then
                LogInventoryAccessDenied(src, toInventory, 'multiple-player-targets')
                return
            end
            if otherPlayerId and otherPlayerId ~= src then
                if RSInventoryBusy[otherPlayerId] then return end
                RSInventoryBusy[otherPlayerId] = true
                secondaryPlayerLock = otherPlayerId
            end

            local fromItem = getItem(fromInventory, src, fromSlot)
            local toItem = getItem(toInventory, src, toSlot)

            if not fromItem then
                if Config.Debug then
                    print('[INV_DEBUG_SERVER] ERROR: fromItem is nil. Aborting.')
                end
                return
            end

            if fromInventory:find('^otherplayer%-') and toInventory == 'player' then
                robberyTargetId = tonumber(fromInventory:match('^otherplayer%-(%d+)$'))
                robberyItemName = fromItem.name
                robberyAmount = toAmount
                local targetId = robberyTargetId
                local RobberPlayer = Player
                local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
                if RobberPlayer and TargetPlayer then
                    local logFields = {
                        { name = "Stolen Item", value = string.format("```Item: %s\nAmount: %s```", fromItem.label, toAmount) },
                        { name = "Robber", value = string.format("```Name: %s\nID: %s```", RobberPlayer.PlayerData.name, RobberPlayer.PlayerData.source), inline = true },
                        { name = "Victim", value = string.format("```Name: %s\nID: %s```", TargetPlayer.PlayerData.name, TargetPlayer.PlayerData.source), inline = true }
                    }
                    SendRobberyLogToDiscord("Item Stolen During Robbery", 15158332, logFields) -- Red Color
                end
            end

            if Config.Debug then
                print('[INV_DEBUG_SERVER] > fromItem: ' .. json.encode(fromItem))
                print('[INV_DEBUG_SERVER] > toItem: ' .. json.encode(toItem))
            end

            local serverFromAmount = fromItem.amount
            if toAmount > serverFromAmount then
                if Config.Debug then
                    print(('[INV_DEBUG_SERVER] ERROR: Client tried to move %s but server only has %s. Aborting.'):format(toAmount, serverFromAmount))
                end
                return
            end
            local fromItemInfo = QBCore.Shared.Items[fromItem.name]
            if not fromItemInfo then return end
            local fromId = getIdentifier(fromInventory, src)
            local toId = getIdentifier(toInventory, src)

            if fromInventory == toInventory then
                if Config.Debug then
                    print('[INV_DEBUG_SERVER] > Action: Same Inventory Move')
                end
                local inventoryId = fromId
                local TargetPlayer = QBCore.Functions.GetPlayer(inventoryId)
                local isDrop = Drops[inventoryId]
                local isStash = Inventories[inventoryId]
                local inventoryItems =
                    (TargetPlayer and TargetPlayer.PlayerData.items) or
                        (isDrop and isDrop.items) or (isStash and isStash.items)
                if not inventoryItems then return end
                local isSplit = not toItem and toAmount < serverFromAmount
                if isSplit then
                    if Config.Debug then
                        print('[INV_DEBUG_SERVER] > Logic Path: isSplit')
                    end
                    inventoryItems[fromSlot].amount = serverFromAmount - toAmount
                    local newItem = table_copy(fromItem)
                    newItem.amount = toAmount
                    newItem.slot = toSlot
                    inventoryItems[toSlot] = newItem
                elseif toItem then
                    local canStack = fromItem.name == toItem.name and
                                         not fromItemInfo.unique
                    if canStack and Config.StackWithDifferentExpiry == false then
                        local fromInfo = type(fromItem.info) == 'table' and fromItem.info or {}
                        local toInfo = type(toItem.info) == 'table' and toItem.info or {}
                        canStack = (not fromInfo.expiryDate or
                                       (fromInfo.expiryDate and
                                           toInfo.expiryDate and
                                           fromInfo.expiryDate == toInfo.expiryDate))
                    end
                    if canStack then
                        if Config.Debug then
                            print('[INV_DEBUG_SERVER] > Logic Path: canStack')
                        end
                        inventoryItems[toSlot].amount =
                            inventoryItems[toSlot].amount + toAmount

                        -- Merged stacks keep the earlier expiry so stacking never extends item life.
                        local fromExpiry = type(fromItem.info) == 'table' and fromItem.info.expiryDate or nil
                        if fromExpiry then
                            if type(inventoryItems[toSlot].info) ~= 'table' then
                                inventoryItems[toSlot].info = {}
                            end
                            local toExpiry = inventoryItems[toSlot].info.expiryDate
                            inventoryItems[toSlot].info.expiryDate =
                                (toExpiry and math.min(toExpiry, fromExpiry)) or fromExpiry
                        end

                        inventoryItems[fromSlot].amount =
                            inventoryItems[fromSlot].amount - toAmount
                        if inventoryItems[fromSlot].amount <= 0 then
                            inventoryItems[fromSlot] = nil
                        end
                    else
                        -- A non-stack target is a full-slot swap. Treat a client
                        -- request for only part of the source stack as invalid
                        -- rather than silently moving the entire stack.
                        if toAmount ~= serverFromAmount then
                            LogInventoryAccessDenied(src, fromInventory, 'partial-swap-request')
                            return
                        end
                        if Config.Debug then
                            print('[INV_DEBUG_SERVER] > Logic Path: Swap (Safe Method)')
                        end
                        local tempFromItem = table_copy(inventoryItems[fromSlot])
                        local tempToItem = table_copy(inventoryItems[toSlot])
                        inventoryItems[fromSlot] = tempToItem
                        inventoryItems[fromSlot].slot = fromSlot
                        inventoryItems[toSlot] = tempFromItem
                        inventoryItems[toSlot].slot = toSlot
                    end
                else
                    if Config.Debug then
                        print('[INV_DEBUG_SERVER] > Logic Path: Move to empty slot')
                    end
                    inventoryItems[toSlot] = fromItem
                    inventoryItems[fromSlot] = nil
                    inventoryItems[toSlot].slot = toSlot
                end
                if TargetPlayer then
                    TargetPlayer.Functions.SetPlayerData('items', inventoryItems)
                    ScheduleSave(inventoryId)
                elseif isDrop then
                    Drops[inventoryId].items = inventoryItems
                elseif isStash then
                    Inventories[inventoryId].items = inventoryItems
                    if ScheduleInventorySave then ScheduleInventorySave(inventoryId) end
                end
                moveCompleted = true
            else
                if Config.Debug then
                    print('[INV_DEBUG_SERVER] > Action: Different Inventory Move')
                end
                local function rollback(message)
                    print(('[qb-inventory] CRITICAL ERROR: %s. Rolling back transaction.'):format(message))
                    AddItem(fromId, fromItem.name, toAmount, fromSlot, fromItem.info, 'move_failed_rollback')
                end

                local canStackAcross = toItem and fromItem.name == toItem.name and
                                           not fromItemInfo.unique
                if canStackAcross and Config.StackWithDifferentExpiry == false then
                    local fromInfo = type(fromItem.info) == 'table' and fromItem.info or {}
                    local toInfo = type(toItem.info) == 'table' and toItem.info or {}
                    canStackAcross = (not fromInfo.expiryDate or
                                         (fromInfo.expiryDate and
                                             toInfo.expiryDate and
                                             fromInfo.expiryDate == toInfo.expiryDate))
                end

                if canStackAcross then
                    if Config.Debug then
                        print('[INV_DEBUG_SERVER] > Logic Path: canStackAcross')
                    end
                    -- Preserve the moving item's info (not the target's) so AddItem can
                    -- merge freshness/expiry correctly when the stacks differ.
                    local movingInfo = type(fromItem.info) == 'table' and fromItem.info or toItem.info
                    if RemoveItem(fromId, fromItem.name, toAmount, fromSlot, 'stacked item') then
                        if AddItem(toId, toItem.name, toAmount, toSlot, movingInfo, 'stacked item') then
                            moveCompleted = true
                        else
                            rollback('AddItem failed when stacking across inventories')
                        end
                    end
                elseif not toItem and toAmount < serverFromAmount then
                    if Config.Debug then
                        print('[INV_DEBUG_SERVER] > Logic Path: Split across inventories')
                    end
                    local canAdd, reason = CanAddItem(toId, fromItem.name, toAmount)
                    if canAdd then
                        if RemoveItem(fromId, fromItem.name, toAmount, fromSlot, 'split item') then
                            if AddItem(toId, fromItem.name, toAmount, toSlot, fromItem.info, 'split item') then
                                moveCompleted = true
                            else
                                rollback('AddItem failed when splitting across inventories')
                            end
                        end
                    else
                        if Config.Debug then
                            print(('[INV_DEBUG_SERVER] Move aborted: Cannot split item to target. Reason: %s'):format(reason))
                        end
                        local msg = reason == 'weight' and 'Target inventory does not have enough space.' or 'Target inventory has no free slots.'
                        TriggerClientEvent('QBCore:Notify', src, msg, 'error')
                    end
                else
                    if toItem then
                        if toAmount ~= serverFromAmount then
                            LogInventoryAccessDenied(src, fromInventory, 'partial-cross-swap-request')
                            return
                        end
                        if Config.Debug then
                            print('[INV_DEBUG_SERVER] > Logic Path: Swap across inventories')
                        end
                        local toItemAmount = toItem.amount
                        -- Both destination slots are already occupied. CanAddItem
                        -- falsely rejects legitimate swaps when an inventory is
                        -- full because it evaluates the incoming stack before the
                        -- outgoing stack has freed its weight/slot. Validate the
                        -- projected post-swap weights instead; slot count is
                        -- unchanged for a full occupied-slot swap.
                        local canAddTo, reasonTo = CanReceiveFullSwap(toId, toItem, fromItem)
                        local canAddFrom, reasonFrom = CanReceiveFullSwap(fromId, fromItem, toItem)
                        if canAddTo and canAddFrom then
                            local removedFrom = RemoveItem(fromId, fromItem.name,
                                                           serverFromAmount, fromSlot,
                                                           'swapped item')
                            if removedFrom then
                                local removedTo = RemoveItem(toId, toItem.name,
                                                            toItemAmount, toSlot,
                                                            'swapped item')
                                if not removedTo then
                                    AddItem(fromId, fromItem.name, serverFromAmount,
                                            fromSlot, fromItem.info,
                                            'swap-remove-rollback')
                                else
                                    local addedTo = AddItem(toId, fromItem.name,
                                                            serverFromAmount, toSlot,
                                                            fromItem.info,
                                                            'swapped item')
                                    if not addedTo then
                                        AddItem(toId, toItem.name, toItemAmount,
                                                toSlot, toItem.info,
                                                'swap-add-rollback')
                                        AddItem(fromId, fromItem.name,
                                                serverFromAmount, fromSlot,
                                                fromItem.info,
                                                'swap-add-rollback')
                                    else
                                        local addedFrom = AddItem(fromId,
                                                                  toItem.name,
                                                                  toItemAmount,
                                                                  fromSlot,
                                                                  toItem.info,
                                                                  'swapped item')
                                        if addedFrom then
                                            moveCompleted = true
                                        else
                                            RemoveItem(toId, fromItem.name,
                                                       serverFromAmount, toSlot,
                                                       'swap-final-rollback')
                                            AddItem(toId, toItem.name,
                                                    toItemAmount, toSlot,
                                                    toItem.info,
                                                    'swap-final-rollback')
                                            AddItem(fromId, fromItem.name,
                                                    serverFromAmount, fromSlot,
                                                    fromItem.info,
                                                    'swap-final-rollback')
                                        end
                                    end
                                end
                            end
                        else
                            if Config.Debug then
                                print('[INV_DEBUG_SERVER] Swap aborted: One or both inventories cannot hold the swapped item.')
                            end
                            if not canAddTo then
                                local msg = reasonTo == 'weight' and 'Target inventory does not have enough space for this item.' or 'Target inventory has no free slots for this item.'
                                TriggerClientEvent('QBCore:Notify', src, msg, 'error')
                            elseif not canAddFrom then
                                local msg = reasonFrom == 'weight' and 'Your inventory does not have enough space for the swapped item.' or 'Your inventory has no free slots for the swapped item.'
                                TriggerClientEvent('QBCore:Notify', src, msg, 'error')
                            end
                        end
                    else
                        if Config.Debug then
                            print('[INV_DEBUG_SERVER] > Logic Path: Move to empty slot across inventories')
                        end
                        local canAdd, reason = CanAddItem(toId, fromItem.name, serverFromAmount)
                        if canAdd then
                            if RemoveItem(fromId, fromItem.name, serverFromAmount, fromSlot, 'moved item') then
                                if AddItem(toId, fromItem.name, serverFromAmount, toSlot, fromItem.info, 'moved item') then
                                    moveCompleted = true
                                else
                                    rollback('AddItem failed when moving to an empty slot')
                                end
                            end
                        else
                            if Config.Debug then
                                print(('[INV_DEBUG_SERVER] Move aborted: Cannot move item to target. Reason: %s'):format(reason))
                            end
                            local msg = reason == 'weight' and 'Target inventory does not have enough space.' or 'Target inventory has no free slots.'
                            TriggerClientEvent('QBCore:Notify', src, msg, 'error')
                        end
                    end
                end
            end
    end)

    if not ok then
        print(('[qb-inventory] SetInventoryData failed for %s: %s'):format(
            tostring(src), tostring(err)))
    end

    if ok and moveCompleted and robberyTargetId and robberyItemName and
        GetResourceState('rs-incidentlink') == 'started' then
        local eventId = ('qb-inventory:phone-robbery:%s:%s:%s:%s'):format(
            robberyTargetId, src, GetGameTimer(), tostring(requestId or 'move'))
        local incidentOk, result = pcall(function()
            return exports['rs-incidentlink']:ReportInventoryTransfer({
                eventId = eventId,
                inventory = 'qb-inventory',
                fromSource = robberyTargetId,
                toSource = src,
                item = robberyItemName,
                amount = robberyAmount,
                reason = 'stolen_by_player',
                success = true
            })
        end)
        if not incidentOk and Config.Debug then
            print(('[qb-inventory] RS Incident Link robbery signal failed: %s'):format(result))
        end
    end

    if requestId then
        local operationSucceeded = ok and moveCompleted
        TriggerClientEvent('qb-inventory:client:inventoryOperationResult', src,
                           requestId,
                           BuildInventorySnapshot(src, otherInventoryName,
                                                  operationSucceeded,
                                                  not ok and tostring(err) or
                                                  (not moveCompleted and 'move-rejected' or nil)))
    end

    if secondaryPlayerLock then RSInventoryBusy[secondaryPlayerLock] = nil end
    RSInventoryBusy[src] = nil
end)

function ScheduleSave(source)
    source = tonumber(source)
    if not source then return end
    saveCounters[source] = (saveCounters[source] or 0) + 1
    local currentVersion = saveCounters[source]

    SetTimeout(SAVE_DELAY, function()
        if saveCounters[source] == currentVersion and
            QBCore.Functions.GetPlayer(source) then SaveInventory(source) end
    end)
end

-- =================================================================
--                   PLAYER SEARCH FEATURE (ROB)
-- =================================================================

-- Robbery is a three-step handshake and every step used to be advisory. The
-- hands-up check, the 5 second progress bar and the dead check all ran on the
-- client, so triggering `qb-inventory:server:robPlayer` directly skipped the lot
-- and opened the target's inventory instantly.
--
-- The server now issues a single-use token in initiateRob, promotes it only when
-- the victim (or the server's own dead check) says the target is robbable, and
-- robPlayer refuses to do anything without a live token that it consumes.
PendingRobberies = {}

local ROBBERY_HANDSHAKE_TIMEOUT = 10
local ROBBERY_TOKEN_TIMEOUT = 15
local ROBBERY_FINAL_CHECK_TIMEOUT = 5
local ROBBERY_PROGRESS_MS = 5000
local ROBBERY_DISTANCE = 3.0

local function ClearRobbery(robberId)
    PendingRobberies[robberId] = nil
end

local function RobberyDistanceOk(robberId, targetId)
    if not SameRoutingBucket(robberId, targetId) then return false end
    local robberPed = GetPlayerPed(robberId)
    local targetPed = GetPlayerPed(targetId)
    if not robberPed or not targetPed or robberPed == 0 or targetPed == 0 then
        return false
    end
    return #(GetEntityCoords(robberPed) - GetEntityCoords(targetPed)) <= ROBBERY_DISTANCE
end

local function CompleteRobbery(robberId, targetId)
    local RobberPlayer = QBCore.Functions.GetPlayer(robberId)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
    if not RobberPlayer or not TargetPlayer then return false end
    if PlayerInventoryActionBlocked(RobberPlayer) then return false end
    if not RobberyDistanceOk(robberId, targetId) then
        TriggerClientEvent('QBCore:Notify', robberId, 'Target is too far away.', 'error')
        return false
    end
    if IsInventoryServerBusy(targetId) then
        TriggerClientEvent('QBCore:Notify', robberId, 'This person is busy.', 'error')
        return false
    end

    local robberIdentifier = RobberPlayer.PlayerData.license
    local targetIdentifier = TargetPlayer.PlayerData.license
    local robberCitizenId = RobberPlayer.PlayerData.citizenid
    local targetCitizenId = TargetPlayer.PlayerData.citizenid
    local logFields = {
        { name = 'Robber', value = string.format('```Name: %s\nID: %s\nCitizenID: %s\nIdentifier: %s```', GetPlayerName(robberId), robberId, robberCitizenId, robberIdentifier), inline = true },
        { name = 'Victim', value = string.format('```Name: %s\nID: %s\nCitizenID: %s\nIdentifier: %s```', GetPlayerName(targetId), targetId, targetCitizenId, targetIdentifier), inline = true }
    }
    SendRobberyLogToDiscord('Player Robbery Initiated', 16753920, logFields)

    if not TargetPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('qb-inventory:client:beingRobbed', targetId)
    end

    if not OpenInventoryById(robberId, targetId) then
        TriggerClientEvent('QBCore:Notify', robberId, 'This person is busy.', 'error')
        return false
    end
    TriggerClientEvent('QBCore:Notify', targetId, 'You are being searched!', 'error', 7500)
    TriggerClientEvent('QBCore:Notify', robberId, 'You started searching ' .. GetPlayerName(targetId), 'success', 7500)
    return true
end

RegisterNetEvent('robbery:server:initiateRob', function(targetId)
    local src = source
    targetId = tonumber(targetId)
    if not targetId or targetId == src then return end

    local RobberPlayer = QBCore.Functions.GetPlayer(src)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
    if not RobberPlayer or not TargetPlayer or PlayerInventoryActionBlocked(RobberPlayer) then return end

    if not RobberyDistanceOk(src, targetId) then
        TriggerClientEvent('QBCore:Notify', src, 'Target is too far away.', 'error')
        return
    end
    if IsInventoryServerBusy(src) or IsInventoryServerBusy(targetId) then
        TriggerClientEvent('QBCore:Notify', src, 'This person is busy.', 'error')
        return
    end

    if TargetPlayer.PlayerData.metadata['isdead'] or TargetPlayer.PlayerData.metadata['inlaststand'] then
        PendingRobberies[src] = {
            target = targetId,
            stage = 'approved',
            readyAt = GetGameTimer() + ROBBERY_PROGRESS_MS,
            expires = os.time() + ROBBERY_TOKEN_TIMEOUT
        }
        TriggerClientEvent('robbery:client:startRobberyProgress', src, targetId)
        return
    end

    PendingRobberies[src] = {
        target = targetId,
        stage = 'checking',
        expires = os.time() + ROBBERY_HANDSHAKE_TIMEOUT
    }
    TriggerClientEvent('robbery:client:checkIfHandsUp', targetId, src)
end)

RegisterNetEvent('robbery:server:handsUpResult', function(robberId, isHandsUp)
    local targetId = source
    robberId = tonumber(robberId)
    if not robberId then return end

    local pending = PendingRobberies[robberId]
    if not pending or pending.target ~= targetId or
        (pending.stage ~= 'checking' and pending.stage ~= 'final-check') then
        LogInventoryAccessDenied(targetId, 'otherplayer-' .. tostring(robberId),
                                 'robbery-no-handshake')
        return
    end

    if os.time() > pending.expires or not RobberyDistanceOk(robberId, targetId) then
        ClearRobbery(robberId)
        return
    end

    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
    local targetDown = TargetPlayer and
        (TargetPlayer.PlayerData.metadata['isdead'] or TargetPlayer.PlayerData.metadata['inlaststand'])

    if pending.stage == 'final-check' then
        if not targetDown and isHandsUp ~= true then
            ClearRobbery(robberId)
            TriggerClientEvent('QBCore:Notify', robberId,
                               'Target is no longer surrendering.', 'error')
            return
        end
        ClearRobbery(robberId)
        CompleteRobbery(robberId, targetId)
        return
    end

    if not targetDown and isHandsUp ~= true then
        ClearRobbery(robberId)
        TriggerClientEvent('QBCore:Notify', robberId,
                           'Target does not have their hands up.', 'error')
        return
    end

    pending.stage = 'approved'
    pending.readyAt = GetGameTimer() + ROBBERY_PROGRESS_MS
    pending.expires = os.time() + ROBBERY_TOKEN_TIMEOUT
    TriggerClientEvent('robbery:client:startRobberyProgress', robberId, targetId)
end)

RegisterNetEvent('robbery:server:cancelRobbery', function(targetId)
    local src = source
    targetId = tonumber(targetId)
    local pending = PendingRobberies[src]
    if pending and (not targetId or pending.target == targetId) then
        ClearRobbery(src)
    end
end)

RegisterNetEvent('qb-inventory:server:robPlayer', function(targetId)
    local src = source
    targetId = tonumber(targetId)
    if not targetId then return end

    local pending = PendingRobberies[src]
    if not pending or pending.stage ~= 'approved' or pending.target ~= targetId then
        LogInventoryAccessDenied(src, 'otherplayer-' .. tostring(targetId),
                                 'robbery-no-token')
        return
    end

    if os.time() > pending.expires then
        ClearRobbery(src)
        TriggerClientEvent('QBCore:Notify', src, 'The search took too long.', 'error')
        return
    end
    if pending.readyAt and GetGameTimer() < pending.readyAt then
        LogInventoryAccessDenied(src, 'otherplayer-' .. tostring(targetId),
                                 'robbery-progress-skipped')
        return
    end

    local RobberPlayer = QBCore.Functions.GetPlayer(src)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
    if not RobberPlayer or not TargetPlayer or PlayerInventoryActionBlocked(RobberPlayer) then
        ClearRobbery(src)
        return
    end
    if not RobberyDistanceOk(src, targetId) then
        ClearRobbery(src)
        TriggerClientEvent('QBCore:Notify', src, 'Target is too far away.', 'error')
        return
    end
    if IsInventoryServerBusy(targetId) then
        ClearRobbery(src)
        TriggerClientEvent('QBCore:Notify', src, 'This person is busy.', 'error')
        return
    end

    if TargetPlayer.PlayerData.metadata['isdead'] or TargetPlayer.PlayerData.metadata['inlaststand'] then
        ClearRobbery(src)
        CompleteRobbery(src, targetId)
        return
    end

    -- The target was alive when the search began. Re-probe at completion so
    -- lowering hands (or reviving during a dead-body search) cancels access.
    pending.stage = 'final-check'
    pending.expires = os.time() + ROBBERY_FINAL_CHECK_TIMEOUT
    TriggerClientEvent('robbery:client:checkIfHandsUp', targetId, src)
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source) or source

    -- Do not depend on QBCore:Server:PlayerUnloaded firing before/after this
    -- native disconnect event. Server IDs are recycled; carrying a stale
    -- mutation mutex, drop request, or debounced-save generation into the next
    -- player assigned the same ID can brick inventory actions or run old timers
    -- against the wrong character. Make raw playerDropped independently final.
    saveCounters[src] = nil
    activeDropRequests[src] = nil
    completedDropRequests[src] = nil
    RSInventoryBusy[src] = nil
    lastVendingOpen[src] = nil
    lastUseItem[src] = nil
    lastSnapshotRequest[src] = nil
    lastDropListRequest[src] = nil
    lastMoveRequest[src] = nil
    usedItemReservations[src] = nil
    RegisteredShops['vending-' .. src] = nil
    PendingRobberies[src] = nil
    -- Drop any token naming this player as the victim, and release bags they held.
    for robberId, pending in pairs(PendingRobberies) do
        if pending.target == src then PendingRobberies[robberId] = nil end
    end

    local ped = GetPlayerPed(src)
    local lastCoords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    for _, drop in pairs(Drops) do
        if drop.carrier == src then
            if lastCoords then drop.coords = lastCoords end
            drop.carrier = nil
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- Player inventory mutations are debounced during normal play. A manual
    -- `restart qb-inventory` can occur inside that debounce window, so save every
    -- live player before tearing down server-owned drops/state. Stash data has
    -- its own dirty flush handler in functions.lua.
    for _, playerId in pairs(QBCore.Functions.GetPlayers()) do
        SaveInventory(playerId)
    end

    for dropId, drop in pairs(Drops) do
        if drop and drop.entityId then
            TriggerClientEvent('qb-inventory:client:removeDropTarget', -1, drop.entityId)
            local entity = NetworkGetEntityFromNetworkId(drop.entityId)
            if entity and entity ~= 0 and DoesEntityExist(entity) then DeleteEntity(entity) end
        end
        Drops[dropId] = nil
    end
end)

