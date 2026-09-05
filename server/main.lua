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

function SanitizeInventory(items)
    if not items or type(items) ~= 'table' then return {} end
    local sanitizedItems = {}
    for k, v in pairs(items) do
        local slot = tonumber(k)
        if slot and v and type(v) == 'table' then
            v.slot = slot
            sanitizedItems[slot] = v
        end
    end
    return sanitizedItems
end

exports('IsCashAsItem', function() return Config.CashAsItem end)

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
                Inventories[cacheKey] = {
                    items = SanitizeInventory(json.decode(inventory.items)),
                    isOpen = false
                }
            end
            --   print(#result .. ' inventories successfully loaded')
        end
    end)
end)

CreateThread(function()
    while true do
        for k, v in pairs(Drops) do
            if v and (v.createdTime + ((Config.CleanupDropTime or 15) * 60) < os.time()) and
                not Drops[k].isOpen then
                local entity = NetworkGetEntityFromNetworkId(v.entityId)
                if DoesEntityExist(entity) then
                    DeleteEntity(entity)
                end
                Drops[k] = nil
            end
        end
        Wait((Config.CleanupDropInterval or 1) * 60000)
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
    for inventory, data in pairs(Inventories) do
        if data.isOpen then
            MySQL.prepare(
                'INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?',
                {inventory, json.encode(data.items), json.encode(data.items)})
        end
    end
end)

RegisterNetEvent('QBCore:Server:UpdateObject', function()
    if source ~= '' then return end
    QBCore = exports['qb-core']:GetCoreObject()
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)

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
    if not Player then return end

    local now = GetGameTimer()
    local lastOpen = lastVendingOpen[src] or 0
    if now - lastOpen < 1000 then return end
    lastVendingOpen[src] = now

    -- The shop used to be built from client-supplied `data.coords`, and
    -- attemptPurchase then validated the player's distance against those same
    -- coords, so the check compared the attacker's number against itself.
    -- The player's real server-side position is used instead, which makes the
    -- purchase-time check mean "you have not walked away from the machine".
    --
    -- The key is per-player because a single global 'vending' entry meant two
    -- players at two different machines overwrote each other.
    local shopName = 'vending-' .. src
    local playerCoords = GetEntityCoords(GetPlayerPed(src))

    CreateShop({
        name = shopName,
        label = 'Vending Machine',
        coords = playerCoords,
        slots = #Config.VendingItems,
        items = Config.VendingItems
    })
    TriggerClientEvent('qb-inventory:client:sendServerTime', source, os.time())
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
    if inventory ~= nil and type(inventory) ~= 'string' then
        return
    end

    -- Player-only inventory has no secondary name. If a secondary session does
    -- exist but the client omitted the name, close the server's real session
    -- instead of leaving a target/stash/drop locked.
    if (not inventory or inventory == '') and session then
        inventory = session.name
    end

    -- Lua treats the empty string as truthy. The NUI deliberately sends
    -- name = "" when only the player's own inventory is open, so only a
    -- non-empty secondary name should be subject to the session guard. An
    -- empty/nil close is idempotent and must still clear inv_busy.
    local hasNamedInventory = type(inventory) == 'string' and inventory ~= ''

    if hasNamedInventory and not session then
        LogInventoryAccessDenied(src, inventory, 'close-no-session')
        return
    end
    if session and hasNamedInventory and session.name ~= inventory then
        LogInventoryAccessDenied(src, inventory, 'close-session-mismatch')
        return
    end

    Player(src).state.inv_busy = false
    ClearInventorySession(src)

    if type(inventory) ~= 'string' or inventory == '' then return end
    if inventory:find('^shop%-') then return end

    if inventory:find('^otherplayer%-') then
        local targetId = tonumber(inventory:match('^otherplayer%-(.+)'))
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
            TriggerClientEvent('qb-inventory:client:removeDropTarget', -1,
                               Drops[inventory].entityId)
            Wait(500)
            local entity = NetworkGetEntityFromNetworkId(Drops[inventory].entityId)
            if DoesEntityExist(entity) then DeleteEntity(entity) end
            Drops[inventory] = nil
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

    CreateThread(function()
        MySQL.prepare.await(
            'INSERT INTO inventories (identifier, items) VALUES (?, ?) ON DUPLICATE KEY UPDATE items = ?',
            {
                inventory, json.encode(Inventories[inventory].items),
                json.encode(Inventories[inventory].items)
            })
    end)
end)

RegisterNetEvent('qb-inventory:server:useItem', function(item)
    local src = source
    if type(item) ~= 'table' then return end

    local slot = tonumber(item.slot)
    if not slot or slot ~= math.floor(slot) or slot < 1 or slot > Config.MaxSlots then
        return
    end

    local itemData = GetItemBySlot(src, slot)
    if not itemData then return end
    if itemData.name == 'cash' then return end

    local itemInfo = QBCore.Shared.Items[itemData.name]
    if not itemInfo then return end
    local itemMeta = type(itemData.info) == 'table' and itemData.info or {}

    if itemMeta.expiryDate and os.time() >= itemMeta.expiryDate then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('notify.item_expired'),
                           'error')
        return
    end

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
    if type(dropId) ~= 'string' then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player(src).state.inv_busy then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local drop = Drops[dropId]
    if not drop then return end
    if drop.isOpen then return end
    local distance = #(playerCoords - drop.coords)
    if distance > 2.5 then return end
    local formattedInventory = {
        name = dropId,
        label = dropId,
        maxweight = drop.maxweight,
        slots = drop.slots,
        inventory = drop.items
    }
    drop.isOpen = src
    Player(src).state.inv_busy = true
    SetInventorySession(src, dropId, 'drop')
    TriggerClientEvent('qb-inventory:client:sendServerTime', source, os.time())
    TriggerClientEvent('qb-inventory:client:openInventory', source,
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
    if not Player or not drop then
        cb(false)
        return
    end

    if drop.carrier and drop.carrier ~= src and GetPlayerName(drop.carrier) then
        cb(false)
        return
    end

    if drop.isOpen and drop.isOpen ~= src then
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

    -- Release any bag this player was already carrying.
    for _, existing in pairs(Drops) do
        if existing.carrier == src then existing.carrier = nil end
    end

    drop.carrier = src
    cb(true)
end)

RegisterNetEvent('qb-inventory:server:updateDrop', function(dropId, coords)
    local src = source

    if type(dropId) ~= 'string' then
        LogInventoryAccessDenied(src, dropId, 'drop-bad-id')
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

    local newCoords = NormalizeInventoryCoords(coords)
    if not newCoords then
        LogInventoryAccessDenied(src, dropId, 'drop-bad-coords')
        return
    end

    -- A bag is set down at the carrier's feet, so the reported position has to
    -- agree with where the server thinks that player actually is.
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    if #(playerCoords - newCoords) > 5.0 then
        LogInventoryAccessDenied(src, dropId, 'drop-coords-mismatch')
        return
    end

    drop.coords = newCoords
    drop.carrier = nil
end)

QBCore.Functions.CreateCallback('qb-inventory:server:GetCurrentDrops',
                                function(_, cb)
    local publicDrops = {}
    for dropName, drop in pairs(Drops) do
        if drop and drop.entityId then
            publicDrops[dropName] = { entityId = drop.entityId }
        end
    end
    cb(publicDrops)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:createDrop',
                                function(source, cb, item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(item) ~= 'table' then
        cb(false)
        return
    end

    local operationId = tostring(item.operationId or '')
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

    -- The UI can only actively own one floor drop at a time. Release any
    -- previous drop lock before switching the right panel to the new bag.
    for _, existingDrop in pairs(Drops) do
        if existingDrop.isOpen == src then existingDrop.isOpen = false end
    end

    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)

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
        local freeSlot = GetFirstFreeSlot(Drops[newDropId].items,
                                          Drops[newDropId].slots)
        if not freeSlot then
            DeleteEntity(bag)
            AddItem(src, originalItem.name, amountToDrop, fromSlot,
                    originalItem.info, 'drop-full-refund')
            finish(false)
            return
        end
        newItemForDrop.slot = freeSlot
        Drops[newDropId].items[freeSlot] = newItemForDrop
    else
        Drops[newDropId] = {
            name = newDropId,
            label = 'Drop',
            items = {[1] = newItemForDrop},
            entityId = dropId,
            createdTime = os.time(),
            coords = playerCoords,
            maxweight = Config.DropSize.maxweight,
            slots = Config.DropSize.slots,
            isOpen = src
        }
        TriggerClientEvent('qb-inventory:client:setupDropTarget', -1, dropId)
    end

    Drops[newDropId].isOpen = src
    SetInventorySession(src, newDropId, 'drop')

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
    if not Player or not shopInfo then
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

    local unitPrice = tonumber(shopItem.price) or 0
    if unitPrice < 0 then
        cb(false)
        return
    end
    local price = unitPrice * amount
    local canPay = price == 0 or RemoveCash(source, price, 'shop-purchase')

    if canPay then
        -- Price, item identity and metadata all come from the registered
        -- server-side shop entry; the browser is not authoritative here.
        local purchaseInfo = CopyTable(shopItem.info or {})

        if AddItem(source, shopItem.name, amount, nil, purchaseInfo,
                   'shop-purchase') then
            TriggerEvent('qb-shops:server:UpdateShopItems', shop, shopItem,
                         amount)
            TriggerClientEvent('qb-inventory:client:updateInventory', source,
                               Player.PlayerData.items)
            cb(true)
        else
            if price > 0 then
                AddCash(source, price, 'shop-purchase-failed-refund')
            end
            TriggerClientEvent('QBCore:Notify', source,
                               'Transaction failed, could not add item.',
                               'error')
            cb(false)
        end
    else
        TriggerClientEvent('QBCore:Notify', source,
                           'You do not have enough money', 'error')
        cb(false)
    end
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

    local pCoords = GetEntityCoords(GetPlayerPed(source))
    local tCoords = GetEntityCoords(GetPlayerPed(targetId))
    if #(pCoords - tCoords) > 5.0 then
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

    local serverItem = player.PlayerData.items and player.PlayerData.items[slot]
    if not serverItem or type(serverItem.name) ~= 'string' or
        amount > (tonumber(serverItem.amount) or 0) then
        cb(false)
        return
    end

    local item = serverItem.name:lower()
    local itemInfo = QBCore.Shared.Items[item]
    if not itemInfo then
        cb(false)
        return
    end
    local info = CopyTable(serverItem.info or {})

    if RemoveItem(source, item, amount, slot,
                  'Item given to ID #' .. targetId) then
        if AddItem(targetId, item, amount, false, info,
                   'Item received from ID #' .. source) then
            if itemInfo.type == 'weapon' then
                checkWeapon(source, item)
            end

            TriggerClientEvent('qb-inventory:client:giveAnim', source)
            TriggerClientEvent('qb-inventory:client:giveAnim', targetId)

            if Player(targetId).state.inv_busy then
                TriggerClientEvent('qb-inventory:client:updateInventory',
                                   targetId, Target.PlayerData.items)
            end

            cb(true)
        else
            AddItem(source, item, amount, slot, info,
                    'Failed to give item, returned.')
            cb(false)
        end
    else
        cb(false)
    end
end)

local function getItem(inventoryId, src, slot)
    local items = {}
    if inventoryId == 'player' then
        local Player = QBCore.Functions.GetPlayer(src)
        if Player and Player.PlayerData.items then
            items = Player.PlayerData.items
        end
    elseif inventoryId:find('otherplayer-') then
        local targetId = tonumber(inventoryId:match('otherplayer%-(.+)'))
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
    elseif inventoryId:find('otherplayer-') then
        return tonumber(inventoryId:match('otherplayer%-(.+)'))
    else
        return inventoryId
    end
end


local function BuildOtherInventorySnapshot(inventoryName)
    if type(inventoryName) ~= 'string' or inventoryName == '' or
        inventoryName == 'player' then
        return nil
    end

    if inventoryName:find('otherplayer%-') == 1 then
        local targetId = tonumber(inventoryName:match('otherplayer%-(.+)'))
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
    if otherInventoryName ~= nil then
        if type(otherInventoryName) ~= 'string' then
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
            if toInventory:find('shop%-') then return end

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

            local fromItem = getItem(fromInventory, src, fromSlot)
            local toItem = getItem(toInventory, src, toSlot)

            if not fromItem then
                if Config.Debug then
                    print('[INV_DEBUG_SERVER] ERROR: fromItem is nil. Aborting.')
                end
                return
            end

            if fromInventory:find('otherplayer-') and toInventory == 'player' then
                robberyTargetId = tonumber(fromInventory:match('otherplayer%-(.+)'))
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
                end
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
                        if Config.Debug then
                            print('[INV_DEBUG_SERVER] > Logic Path: Swap across inventories')
                        end
                        local toItemAmount = toItem.amount
                        local canAddTo, reasonTo = CanAddItem(toId, fromItem.name, serverFromAmount)
                        local canAddFrom, reasonFrom = CanAddItem(fromId, toItem.name, toItemAmount)
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
        TriggerClientEvent('qb-inventory:client:inventoryOperationResult', src,
                           requestId,
                           BuildInventorySnapshot(src, otherInventoryName, ok,
                                                  not ok and tostring(err) or nil))
    end

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

local ROBBERY_HANDSHAKE_TIMEOUT = 10   -- seconds to answer the hands-up probe
local ROBBERY_TOKEN_TIMEOUT     = 15   -- seconds to finish the progress bar
local ROBBERY_DISTANCE          = 3.0

local function ClearRobbery(robberId)
    PendingRobberies[robberId] = nil
end

local function RobberyDistanceOk(robberId, targetId)
    local robberPed = GetPlayerPed(robberId)
    local targetPed = GetPlayerPed(targetId)
    if not robberPed or not targetPed or robberPed == 0 or targetPed == 0 then
        return false
    end
    return #(GetEntityCoords(robberPed) - GetEntityCoords(targetPed)) <= ROBBERY_DISTANCE
end

RegisterNetEvent('robbery:server:initiateRob', function(targetId)
    local src = source
    targetId = tonumber(targetId)
    if not targetId or targetId == src then return end

    local RobberPlayer = QBCore.Functions.GetPlayer(src)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)

    if not RobberPlayer or not TargetPlayer then return end

    if not RobberyDistanceOk(src, targetId) then
        TriggerClientEvent('QBCore:Notify', src, 'Target is too far away.',
                           'error')
        return
    end

    if Player(targetId).state.inv_busy then
        TriggerClientEvent('QBCore:Notify', src, 'This person is busy.', 'error')
        return
    end

    if TargetPlayer.PlayerData.metadata['isdead'] then
        -- A dead target is verified server side, so the token is live immediately.
        PendingRobberies[src] = {
            target = targetId,
            stage = 'approved',
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

    -- Only the player actually being probed may answer, and only for the robber
    -- the server paired them with.
    local pending = PendingRobberies[robberId]
    if not pending or pending.stage ~= 'checking' or pending.target ~= targetId then
        LogInventoryAccessDenied(targetId, 'otherplayer-' .. tostring(robberId),
                                 'robbery-no-handshake')
        return
    end

    if os.time() > pending.expires then
        ClearRobbery(robberId)
        return
    end

    if not isHandsUp then
        ClearRobbery(robberId)
        TriggerClientEvent('QBCore:Notify', robberId,
                           'Target does not have their hands up.', 'error')
        return
    end

    pending.stage = 'approved'
    pending.expires = os.time() + ROBBERY_TOKEN_TIMEOUT
    TriggerClientEvent('robbery:client:startRobberyProgress', robberId, targetId)
end)

RegisterNetEvent('qb-inventory:server:robPlayer', function(targetId)
    local src = source
    targetId = tonumber(targetId)
    if not targetId then return end

    -- The token is the gate. No token, no robbery, however this event was fired.
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

    -- Single use: consumed here whether or not the checks below pass.
    ClearRobbery(src)

    local RobberPlayer = QBCore.Functions.GetPlayer(src)
    local TargetPlayer = QBCore.Functions.GetPlayer(targetId)
    if not RobberPlayer or not TargetPlayer then return end

    if not RobberyDistanceOk(src, targetId) then
        TriggerClientEvent('QBCore:Notify', src, 'Target is too far away.', 'error')
        return
    end

    if Player(targetId).state.inv_busy then
        TriggerClientEvent('QBCore:Notify', src, 'This person is busy.', 'error')
        return
    end

    local robberIdentifier = RobberPlayer.PlayerData.license
    local targetIdentifier = TargetPlayer.PlayerData.license
    local robberCitizenId = RobberPlayer.PlayerData.citizenid
    local targetCitizenId = TargetPlayer.PlayerData.citizenid

    local logFields = {
        { name = "Robber", value = string.format("```Name: %s\nID: %s\nCitizenID: %s\nIdentifier: %s```", GetPlayerName(src), src, robberCitizenId, robberIdentifier), inline = true },
        { name = "Victim", value = string.format("```Name: %s\nID: %s\nCitizenID: %s\nIdentifier: %s```", GetPlayerName(targetId), targetId, targetCitizenId, targetIdentifier), inline = true }
    }
    SendRobberyLogToDiscord("Player Robbery Initiated", 16753920, logFields) -- Orange Color

    if not TargetPlayer.PlayerData.metadata['isdead'] then
        TriggerClientEvent('qb-inventory:client:beingRobbed', targetId)
    end

    if not OpenInventoryById(src, targetId) then
        TriggerClientEvent('QBCore:Notify', src,
                           'This person is busy.', 'error')
        return
    end
    TriggerClientEvent('QBCore:Notify', targetId, 'You are being searched!', 'error', 7500)
    TriggerClientEvent('QBCore:Notify', src, 'You started searching ' .. GetPlayerName(targetId), 'success', 7500)
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastVendingOpen[src] = nil
    PendingRobberies[src] = nil
    -- Drop any token naming this player as the victim, and release bags they held.
    for robberId, pending in pairs(PendingRobberies) do
        if pending.target == src then PendingRobberies[robberId] = nil end
    end
    for _, drop in pairs(Drops) do
        if drop.carrier == src then drop.carrier = nil end
    end
end)

