---------------------------
-- server/sessions.lua
---------------------------
-- Server-authoritative record of which secondary inventory each player has open.
--
-- SECURITY NOTE
-- `qb-inventory:server:SetInventoryData` used to trust the `fromInventory` and
-- `toInventory` strings the client sent. Nothing checked that the player had
-- that inventory open, was anywhere near it, or had gone through the robbery
-- flow. The `isOpen` field was written on open and then never consulted. That
-- let any client pull items straight out of any online player, any drop, or any
-- cached stash with a single event:
--
--     TriggerServerEvent('qb-inventory:server:SetInventoryData',
--                        'otherplayer-7', 'player', 1, 1, 999, 999, 'x')
--
-- Every server-side open path now records a session here, and SetInventoryData
-- refuses to touch any inventory that is not the caller's own or the exact one
-- their session says they have open. Distance is revalidated on every move, so
-- opening legitimately and then walking away does not keep the door open.

local QBCore = exports['qb-core']:GetCoreObject()

InventorySessions = {}

local DROP_ACCESS_DISTANCE = tonumber(Config and Config.DropAccessDistance) or 3.5
local PLAYER_ACCESS_DISTANCE = tonumber(Config and Config.PlayerAccessDistance) or 3.5
local SHOP_ACCESS_DISTANCE = tonumber(Config and Config.ShopAccessDistance) or 6.0

-- Accepts a vector3 or a {x,y,z} / {1,2,3} table and returns a real vector3,
-- or nil for anything else. Client-reported coords arrive as plain tables.
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

function SetInventorySession(src, name, kind)
    src = tonumber(src)
    if not src then return end

    if not name or name == 'player' then
        InventorySessions[src] = nil
        return
    end

    InventorySessions[src] = {
        name = name,
        kind = kind or 'unknown',
        opened = os.time()
    }
end

function ClearInventorySession(src)
    src = tonumber(src)
    if src then InventorySessions[src] = nil end
end

function GetInventorySession(src)
    return InventorySessions[tonumber(src) or 0]
end

function LogInventoryAccessDenied(src, inventoryName, reason)
    local session = InventorySessions[tonumber(src) or 0]
    local line = ('[qb-inventory] BLOCKED inventory access: source=%s (%s) | requested=%s | session=%s | reason=%s')
        :format(tostring(src), tostring(GetPlayerName(src) or 'unknown'),
                tostring(inventoryName),
                session and tostring(session.name) or 'none',
                tostring(reason))

    print('^1' .. line .. '^7')
    TriggerEvent('qb-log:server:CreateLog', 'anticheat', 'Inventory access denied', 'red', line, false)
end

-- Returns true when `src` is allowed to move items in or out of `name` right
-- now, or false plus a short reason suitable for logging.
function CanAccessInventory(src, name)
    src = tonumber(src)
    if not src then return false, 'bad-source' end
    if type(name) ~= 'string' or name == '' then return false, 'bad-name' end

    -- A player may always touch their own inventory.
    if name == 'player' then return true end

    local session = InventorySessions[src]
    if not session then return false, 'no-session' end
    if session.name ~= name then return false, 'session-mismatch' end

    local srcCoords = GetSourceCoords(src)
    if not srcCoords then return false, 'no-ped' end

    local targetId = tonumber(name:match('^otherplayer%-(.+)'))
    if targetId then
        if not QBCore.Functions.GetPlayer(targetId) then return false, 'target-offline' end
        if not Player(targetId).state.inv_busy then return false, 'target-not-busy' end

        local targetCoords = GetSourceCoords(targetId)
        if not targetCoords then return false, 'target-no-ped' end
        if #(srcCoords - targetCoords) > PLAYER_ACCESS_DISTANCE then return false, 'target-too-far' end

        return true
    end

    if Drops and Drops[name] then
        local drop = Drops[name]
        if drop.isOpen and drop.isOpen ~= src then return false, 'drop-in-use' end

        local dropCoords = ToVector3(drop.coords)
        if not dropCoords then return false, 'drop-no-coords' end
        if #(srcCoords - dropCoords) > DROP_ACCESS_DISTANCE then return false, 'drop-too-far' end

        return true
    end

    local shopKey = name:match('^shop%-(.+)')
    if shopKey then
        local shop = RegisteredShops and RegisteredShops[shopKey]
        if not shop then return false, 'shop-unknown' end

        local shopCoords = ToVector3(shop.coords)
        if shopCoords and #(srcCoords - shopCoords) > SHOP_ACCESS_DISTANCE then
            return false, 'shop-too-far'
        end

        return true
    end

    if Inventories and Inventories[name] then
        if Inventories[name].isOpen and Inventories[name].isOpen ~= src then
            return false, 'stash-in-use'
        end
        -- Stashes carry no coords in this codebase, so the session match plus the
        -- isOpen owner check is the strongest available gate here.
        return true
    end

    return false, 'unknown-inventory'
end

-- Slot count an inventory actually exposes, used for bounds checking.
function GetInventorySlotCount(name)
    if type(name) ~= 'string' then return Config.MaxSlots end
    if name == 'player' then return Config.MaxSlots end
    if name:find('^otherplayer%-') then return Config.MaxSlots end

    if Drops and Drops[name] then
        return tonumber(Drops[name].slots) or Config.MaxSlots
    end

    local shopKey = name:match('^shop%-(.+)')
    if shopKey and RegisteredShops and RegisteredShops[shopKey] then
        return tonumber(RegisteredShops[shopKey].slots) or Config.MaxSlots
    end

    if Inventories and Inventories[name] then
        return tonumber(Inventories[name].slots) or Config.StashSize.slots
    end

    return Config.MaxSlots
end

-- Lua happily indexes a table at slot 500, 0, -3 or 1.5. The UI cannot render
-- any of those, but they still count against GetSlots.
function IsValidSlot(slot, maxSlots)
    slot = tonumber(slot)
    if not slot then return false end
    if slot ~= math.floor(slot) then return false end
    if slot < 1 then return false end
    if maxSlots and slot > maxSlots then return false end
    return true
end

function IsValidMoveAmount(amount)
    amount = tonumber(amount)
    if not amount then return false end
    if amount ~= math.floor(amount) then return false end
    if amount <= 0 then return false end
    return true
end

AddEventHandler('playerDropped', function()
    ClearInventorySession(source)
end)

AddEventHandler('QBCore:Server:PlayerUnloaded', function(playerOrSource)
    local src = playerOrSource
    if type(playerOrSource) == 'table' and playerOrSource.PlayerData then
        src = playerOrSource.PlayerData.source
    end
    ClearInventorySession(src)
end)
