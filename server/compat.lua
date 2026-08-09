---------------------------
-- server/compat.lua
---------------------------
-- Legacy QBCore event bridge.
--
-- SECURITY NOTE
-- `QBCore:Server:AddItem` and `QBCore:Server:RemoveItem` are net events, so any
-- connected client can trigger them with an arbitrary item name and amount.
-- With Config.CashAsItem enabled that is a direct money printer, and it hands
-- out any weapon or drug in any quantity regardless of the cash setting.
-- Client-originated calls are now refused and logged.
--
-- A resource that legitimately needs to grant or take items must do it server
-- side through the exports:
--     exports['qb-inventory']:AddItem(source, item, amount, slot, info, reason)
--     exports['qb-inventory']:RemoveItem(source, item, amount, slot, reason)

QBCore = exports['qb-core']:GetCoreObject()

-- Leave this false. Setting it true re-opens the item and cash duplication hole
-- for as long as it is enabled. It exists only as a temporary bridge while a
-- broken legacy resource is being tracked down and corrected.
local ALLOW_LEGACY_CLIENT_ITEM_EVENTS = false

local function ResolvePlayerName(src)
    if not src or src == 0 then return 'unknown' end

    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData then
        local charinfo = Player.PlayerData.charinfo
        if charinfo and charinfo.firstname then
            return ('%s %s [%s]'):format(tostring(charinfo.firstname),
                                         tostring(charinfo.lastname or ''),
                                         tostring(Player.PlayerData.citizenid or '?'))
        end
        if Player.PlayerData.name then return tostring(Player.PlayerData.name) end
    end

    return tostring(GetPlayerName(src) or 'unknown')
end

local function LogLegacyItemAttempt(action, src, item, amount, allowed)
    local line = ('[qb-inventory] %s legacy client item event: %s | source=%s (%s) | item=%s | amount=%s')
        :format(allowed and 'ALLOWED' or 'BLOCKED',
                tostring(action), tostring(src), ResolvePlayerName(src),
                tostring(item), tostring(amount))

    if allowed then
        print('^3' .. line .. '^7')
    else
        print('^1' .. line .. '^7')
    end

    TriggerEvent('qb-log:server:CreateLog', 'anticheat', 'Legacy item event',
                 allowed and 'yellow' or 'red', line, false)
end

local function SanitizeLegacyAmount(amount)
    amount = tonumber(amount)
    if not amount then return nil end
    amount = math.floor(amount)
    if amount <= 0 then return nil end
    return amount
end

-- GetInvokingResource() returns nil when an event arrived over the network from
-- a client, and returns the resource name when a server-side script triggered
-- it. That is the discriminator used to tell a legacy server caller apart from
-- a player with an executor.
local function HandleLegacyItemEvent(action, src, item, amount, slot, info)
    if not item or amount == nil then return end

    local fromServer = GetInvokingResource() ~= nil

    if not fromServer and not ALLOW_LEGACY_CLIENT_ITEM_EVENTS then
        LogLegacyItemAttempt(action, src, item, amount, false)
        return
    end

    local safeAmount = SanitizeLegacyAmount(amount)
    if not safeAmount then
        LogLegacyItemAttempt(action, src, item, amount, false)
        return
    end

    if not fromServer then
        LogLegacyItemAttempt(action, src, item, safeAmount, true)
    end

    if action == 'AddItem' then
        exports['qb-inventory']:AddItem(src, item, safeAmount, slot, info, 'legacy_event_compat')
    else
        exports['qb-inventory']:RemoveItem(src, item, safeAmount, slot, 'legacy_event_compat')
    end
end

RegisterNetEvent('inventory:server:OpenInventory', function(name, data_or_targetid, slots)
    local src = source
    if not name then return end

    if name == 'shop' then
        local shopIdentifier = tostring(data_or_targetid)
        local shopData = slots

        if type(shopData) == 'table' and shopData.items then
            exports['qb-inventory']:CreateShop({
                name = shopIdentifier,
                label = shopData.label or shopIdentifier,
                items = shopData.items
            })

            exports['qb-inventory']:OpenShop(src, shopIdentifier)
        end
    elseif name == 'otherplayer' or name == 'player' then
        local targetId = tonumber(data_or_targetid)
        if not targetId then return end
        exports['qb-inventory']:OpenInventoryById(src, targetId)
    else
        local identifier
        local inventoryData
        if type(slots) == 'table' then
            identifier = data_or_targetid
            inventoryData = slots
            inventoryData.label = inventoryData.label or identifier
        else
            identifier = name
            inventoryData = {
                label = name,
                maxweight = data_or_targetid or Config.StashSize.maxweight,
                slots = slots or Config.StashSize.slots
            }
        end
        if identifier then
            exports['qb-inventory']:OpenInventory(src, identifier, inventoryData)
        end
    end
end)

RegisterNetEvent('QBCore:Server:AddItem', function(item, amount, slot, info)
    HandleLegacyItemEvent('AddItem', source, item, amount, slot, info)
end)

RegisterNetEvent('QBCore:Server:RemoveItem', function(item, amount, slot)
    HandleLegacyItemEvent('RemoveItem', source, item, amount, slot, nil)
end)

QBCore.Functions.CreateCallback('QBCore:Server:HasItem', function(source, cb, item, amount)
    local hasItem = exports['qb-inventory']:HasItem(source, item, amount)
    cb(hasItem)
end)

if ALLOW_LEGACY_CLIENT_ITEM_EVENTS then
    print('^1QB-Inventory: Legacy Compatibility Bridge loaded (client item events ALLOWED - INSECURE).^0')
else
    print('^2QB-Inventory: ^7Legacy Compatibility Bridge loaded (client item events blocked).^0')
end
