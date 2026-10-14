---------------------------
-- server/sessions.lua
---------------------------
-- Server-authoritative inventory session and target-lock layer.
--
-- Replicated `inv_busy` remains useful for QBCore/client compatibility, but it
-- is not a security primitive: clients may be able to write their own state
-- bags unless strict state-bag mode is enabled. Every open/transfer therefore
-- relies on these server-only tables and revalidates the live world state.

local QBCore = exports['qb-core']:GetCoreObject()

InventorySessions = {}
InventoryTargetLocks = {}
local deniedLogState = {}
local DENIED_LOG_INTERVAL_MS = 5000

local DROP_ACCESS_DISTANCE = tonumber(Config and Config.DropAccessDistance) or 3.5
local PLAYER_ACCESS_DISTANCE = tonumber(Config and Config.PlayerAccessDistance) or 3.5
local SHOP_ACCESS_DISTANCE = tonumber(Config and Config.ShopAccessDistance) or 6.0
local STASH_ACCESS_DISTANCE = tonumber(Config and Config.StashAccessDistance) or 8.0
local VEHICLE_ACCESS_DISTANCE = tonumber(Config and Config.VehicleAccessDistance) or 5.0

function NormalizeInventoryCoords(value)
    if value == nil then return nil end
    local valueType = type(value)
    if valueType == 'vector3' then return value end
    if valueType == 'table' then
        local x = tonumber(value.x or value[1])
        local y = tonumber(value.y or value[2])
        local z = tonumber(value.z or value[3])
        if x and y and z then return vector3(x, y, z) end
    end
    return nil
end

local ToVector3 = NormalizeInventoryCoords

local function GetSourceCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

function GetInventoryRoutingBucket(src)
    src = tonumber(src)
    if not src then return nil end
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if ok then return tonumber(bucket) end
    return nil
end

function SameInventoryRoutingBucket(sourceA, sourceB)
    local bucketA = GetInventoryRoutingBucket(sourceA)
    local bucketB = GetInventoryRoutingBucket(sourceB)
    if bucketA == nil or bucketB == nil then return false end
    return bucketA == bucketB
end

local function EntityInPlayerBucket(src, entity)
    if not entity or entity == 0 then return false end
    local playerBucket = GetInventoryRoutingBucket(src)
    if playerBucket == nil then return false end
    local ok, entityBucket = pcall(GetEntityRoutingBucket, entity)
    if not ok then return false end
    return tonumber(entityBucket) == playerBucket
end

local function ReleaseSessionResources(src, session)
    if not session or type(session.name) ~= 'string' then return end
    local name = session.name

    local targetId = tonumber(name:match('^otherplayer%-(%d+)$'))
    if targetId then
        if InventoryTargetLocks[targetId] == src then
            InventoryTargetLocks[targetId] = nil
        end
        if QBCore.Functions.GetPlayer(targetId) then
            Player(targetId).state.inv_busy = false
        end
        return
    end

    if Drops and Drops[name] and Drops[name].isOpen == src then
        Drops[name].isOpen = false
        return
    end

    if Inventories and Inventories[name] and Inventories[name].isOpen == src then
        Inventories[name].isOpen = false
        if SaveStashInventory then
            CreateThread(function()
                if Inventories and Inventories[name] then SaveStashInventory(name) end
            end)
        end
        return
    end

    local shopKey = name:match('^shop%-(.+)')
    if shopKey and shopKey == ('vending-' .. src) and RegisteredShops then
        RegisteredShops[shopKey] = nil
    end
end

function IsInventoryServerBusy(src)
    src = tonumber(src)
    if not src then return true end
    return InventorySessions[src] ~= nil or InventoryTargetLocks[src] ~= nil
end

function GetInventoryTargetLock(targetId)
    return InventoryTargetLocks[tonumber(targetId) or 0]
end

function ReleaseInventorySession(src)
    src = tonumber(src)
    if not src then return end
    local session = InventorySessions[src]
    if session then ReleaseSessionResources(src, session) end
    InventorySessions[src] = nil
end

function SetInventorySession(src, name, kind, context)
    src = tonumber(src)
    if not src or type(name) ~= 'string' or name == '' then return false end

    context = type(context) == 'table' and context or {}
    local bucket = tonumber(context.bucket) or GetInventoryRoutingBucket(src)
    if bucket == nil then return false end

    local targetId = tonumber(name:match('^otherplayer%-(%d+)$'))
    if targetId then
        local currentOpener = InventoryTargetLocks[targetId]
        if currentOpener and currentOpener ~= src then return false end
    end

    local existing = InventorySessions[src]
    if existing and (existing.name ~= name or existing.kind ~= (kind or 'unknown')) then
        ReleaseSessionResources(src, existing)
        InventorySessions[src] = nil
    end

    if targetId then InventoryTargetLocks[targetId] = src end

    InventorySessions[src] = {
        name = name,
        kind = kind or 'unknown',
        opened = os.time(),
        bucket = bucket,
        origin = ToVector3(context.origin) or GetSourceCoords(src),
        anchor = ToVector3(context.anchor),
        accessDistance = tonumber(context.accessDistance),
        netId = tonumber(context.netId),
        prefix = type(context.prefix) == 'string' and context.prefix or nil,
        plate = type(context.plate) == 'string' and context.plate or nil,
        trustedRemote = context.trustedRemote == true,
    }
    return true
end

function ClearInventorySession(src)
    ReleaseInventorySession(src)
end

function GetInventorySession(src)
    return InventorySessions[tonumber(src) or 0]
end

function LogInventoryAccessDenied(src, inventoryName, reason)
    src = tonumber(src) or 0
    reason = tostring(reason or 'unknown')
    deniedLogState[src] = deniedLogState[src] or {}
    local now = GetGameTimer()
    local state = deniedLogState[src][reason]
    if state and (now - state.last) < DENIED_LOG_INTERVAL_MS then
        state.suppressed = (state.suppressed or 0) + 1
        return
    end

    local suppressed = state and state.suppressed or 0
    deniedLogState[src][reason] = { last = now, suppressed = 0 }
    local session = InventorySessions[src]
    local line = ('[qb-inventory] BLOCKED inventory access: source=%s (%s) | requested=%s | session=%s | reason=%s%s')
        :format(tostring(src), tostring(GetPlayerName(src) or 'unknown'), tostring(inventoryName),
                session and tostring(session.name) or 'none', reason,
                suppressed > 0 and (' | suppressed=' .. suppressed) or '')
    print('^1' .. line .. '^7')
    TriggerEvent('qb-log:server:CreateLog', 'anticheat', 'Inventory access denied', 'red', line, false)
end

local function VehicleSessionAccess(src, name, session, srcCoords)
    if not session.netId then return false, 'vehicle-no-netid' end
    local vehicle = NetworkGetEntityFromNetworkId(session.netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false, 'vehicle-gone' end
    if GetEntityType(vehicle) ~= 2 then return false, 'vehicle-not-vehicle' end
    if not EntityInPlayerBucket(src, vehicle) then return false, 'vehicle-bucket-mismatch' end

    local prefix = name:match('^(trunk)%-') or name:match('^(glovebox)%-')
    if not prefix or (session.prefix and session.prefix ~= prefix) then return false, 'vehicle-prefix-mismatch' end

    local okPlate, actualPlate = pcall(GetVehicleNumberPlateText, vehicle)
    if not okPlate or type(actualPlate) ~= 'string' or actualPlate == '' then
        return false, 'vehicle-plate-unavailable'
    end
    local claimed = (name:gsub('^' .. prefix .. '%-', '')):gsub('^%s+', ''):gsub('%s+$', '')
    local normalizedActual = actualPlate:gsub('^%s+', ''):gsub('%s+$', '')
    if claimed ~= normalizedActual then return false, 'vehicle-plate-mismatch' end
    if session.plate and session.plate:gsub('^%s+', ''):gsub('%s+$', '') ~= normalizedActual then
        return false, 'vehicle-session-plate-mismatch'
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'vehicle-no-ped' end
    if prefix == 'glovebox' then
        local okIn, pedVehicle = pcall(GetVehiclePedIsIn, ped, false)
        if not okIn or pedVehicle ~= vehicle then return false, 'glovebox-not-inside' end
        return true
    end

    local maxDistance = session.accessDistance or VEHICLE_ACCESS_DISTANCE
    if #(srcCoords - GetEntityCoords(vehicle)) > maxDistance then return false, 'vehicle-too-far' end
    return true
end

function CanAccessInventory(src, name)
    src = tonumber(src)
    if not src then return false, 'bad-source' end
    if type(name) ~= 'string' or name == '' then return false, 'bad-name' end

    local session = InventorySessions[src]
    if not session then return false, 'no-session' end

    -- A secondary inventory session also authorizes the player's own side of
    -- the two-panel UI. A player-only session is explicitly recorded as such.
    if name == 'player' then return true end
    if session.name ~= name then return false, 'session-mismatch' end

    local currentBucket = GetInventoryRoutingBucket(src)
    if currentBucket == nil or session.bucket == nil then return false, 'routing-unavailable' end
    if session.bucket ~= currentBucket then return false, 'session-bucket-changed' end

    local srcCoords = GetSourceCoords(src)
    if not srcCoords then return false, 'no-ped' end

    local targetId = tonumber(name:match('^otherplayer%-(%d+)$'))
    if targetId then
        if InventoryTargetLocks[targetId] ~= src then return false, 'target-lock-lost' end
        if not QBCore.Functions.GetPlayer(targetId) then return false, 'target-offline' end

        -- Server resources such as the official QBCore admin menu legitimately
        -- use OpenInventoryById remotely. Only a server-originated export call can
        -- create this flag; robbery/client flows never receive it.
        if session.trustedRemote then return true end

        if not SameInventoryRoutingBucket(src, targetId) then return false, 'target-bucket-mismatch' end
        local targetCoords = GetSourceCoords(targetId)
        if not targetCoords then return false, 'target-no-ped' end
        if #(srcCoords - targetCoords) > PLAYER_ACCESS_DISTANCE then return false, 'target-too-far' end
        return true
    end

    if Drops and Drops[name] then
        local drop = Drops[name]
        if drop.isOpen ~= src then return false, 'drop-lock-lost' end
        if drop.carrier then return false, 'drop-carried' end
        local dropBucket = tonumber(drop.bucket)
        if dropBucket == nil or dropBucket ~= currentBucket then return false, 'drop-bucket-mismatch' end
        local dropCoords = ToVector3(drop.coords)
        if not dropCoords then return false, 'drop-no-coords' end
        if #(srcCoords - dropCoords) > DROP_ACCESS_DISTANCE then return false, 'drop-too-far' end
        return true
    end

    local shopKey = name:match('^shop%-(.+)')
    if shopKey then
        local shop = RegisteredShops and RegisteredShops[shopKey]
        if not shop then return false, 'shop-unknown' end
        local shopBucket = tonumber(shop.bucket)
        if shopBucket ~= nil and shopBucket ~= currentBucket then return false, 'shop-bucket-mismatch' end
        local shopCoords = ToVector3(shop.coords)
        if shopCoords and #(srcCoords - shopCoords) > SHOP_ACCESS_DISTANCE then return false, 'shop-too-far' end
        return true
    end

    if session.kind == 'vehicle' then
        return VehicleSessionAccess(src, name, session, srcCoords)
    end

    if Inventories and Inventories[name] then
        if Inventories[name].isOpen ~= src then return false, 'stash-lock-lost' end
        local anchor = session.anchor or session.origin
        local maxDistance = session.accessDistance or STASH_ACCESS_DISTANCE
        if anchor and maxDistance > 0 and #(srcCoords - anchor) > maxDistance then return false, 'stash-too-far' end
        return true
    end

    return false, 'unknown-inventory'
end

function GetInventorySlotCount(name)
    if type(name) ~= 'string' then return Config.MaxSlots end
    if name == 'player' or name:find('^otherplayer%-') then return Config.MaxSlots end
    if Drops and Drops[name] then return tonumber(Drops[name].slots) or Config.MaxSlots end
    local shopKey = name:match('^shop%-(.+)')
    if shopKey and RegisteredShops and RegisteredShops[shopKey] then
        return tonumber(RegisteredShops[shopKey].slots) or Config.MaxSlots
    end
    if Inventories and Inventories[name] then
        return tonumber(Inventories[name].slots) or Config.StashSize.slots
    end
    return Config.MaxSlots
end

function IsValidSlot(slot, maxSlots)
    slot = tonumber(slot)
    if not slot or slot ~= math.floor(slot) or slot < 1 then return false end
    if maxSlots and slot > maxSlots then return false end
    return true
end

function IsValidMoveAmount(amount)
    amount = tonumber(amount)
    if not amount or amount ~= math.floor(amount) or amount <= 0 then return false end
    return true
end

function CleanupInventorySession(src, closeRelatedClient)
    src = tonumber(src)
    if not src then return end

    -- Release anything this player opened, including stash/drop ownership and a
    -- victim lock. This makes playerDropped sufficient even if framework unload
    -- ordering changes or never arrives.
    ReleaseInventorySession(src)

    -- If this player is the victim of an active search, close the opener too.
    local openerId = InventoryTargetLocks[src]
    if openerId then
        InventoryTargetLocks[src] = nil
        local openerSession = InventorySessions[openerId]
        if openerSession then ReleaseSessionResources(openerId, openerSession) end
        InventorySessions[openerId] = nil
        if QBCore.Functions.GetPlayer(openerId) then
            Player(openerId).state.inv_busy = false
            if closeRelatedClient ~= false then TriggerClientEvent('qb-inventory:client:closeInv', openerId) end
        end
    end

    -- Defensive reconciliation for any stale pre-existing session record.
    local victimInventory = 'otherplayer-' .. src
    local staleOpeners = {}
    for candidate, session in pairs(InventorySessions) do
        if session and session.name == victimInventory then staleOpeners[#staleOpeners + 1] = candidate end
    end
    for _, candidate in ipairs(staleOpeners) do
        ReleaseInventorySession(candidate)
        if QBCore.Functions.GetPlayer(candidate) then
            Player(candidate).state.inv_busy = false
            if closeRelatedClient ~= false then TriggerClientEvent('qb-inventory:client:closeInv', candidate) end
        end
    end

    if QBCore.Functions.GetPlayer(src) then Player(src).state.inv_busy = false end
end

-- Revalidate only live inventory sessions. This prevents stale locks when a
-- player teleports/walks away, changes routing buckets, or the vehicle/drop
-- disappears without sending a normal NUI close.
CreateThread(function()
    while true do
        Wait(2000)
        local revoke = {}
        for src, session in pairs(InventorySessions) do
            if not QBCore.Functions.GetPlayer(src) then
                revoke[#revoke + 1] = { src = src, reason = 'player-offline' }
            elseif session and session.name ~= 'player' then
                local allowed, reason = CanAccessInventory(src, session.name)
                if not allowed then revoke[#revoke + 1] = { src = src, reason = reason } end
            end
        end

        for _, entry in ipairs(revoke) do
            local src = entry.src
            if InventorySessions[src] then
                if Config.Debug then
                    print(('[qb-inventory] Closing invalid session source=%s reason=%s')
                        :format(tostring(src), tostring(entry.reason)))
                end
                ReleaseInventorySession(src)
                if QBCore.Functions.GetPlayer(src) then
                    Player(src).state.inv_busy = false
                    TriggerClientEvent('qb-inventory:client:closeInv', src)
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    deniedLogState[tonumber(source) or 0] = nil
    CleanupInventorySession(source, true)
end)

AddEventHandler('QBCore:Server:PlayerUnloaded', function(playerOrSource)
    local src = playerOrSource
    if type(playerOrSource) == 'table' and playerOrSource.PlayerData then src = playerOrSource.PlayerData.source end
    CleanupInventorySession(src, true)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    local players = QBCore.Functions.GetPlayers()
    for _, playerId in pairs(players) do
        if QBCore.Functions.GetPlayer(playerId) then Player(playerId).state.inv_busy = false end
    end
    InventorySessions = {}
    InventoryTargetLocks = {}
end)
