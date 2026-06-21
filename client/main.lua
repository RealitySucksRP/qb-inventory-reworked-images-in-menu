--client/main.lua

QBCore = exports['qb-core']:GetCoreObject()

if not Lang then
    Lang = {
        t = function(_, key)
            local fallback = {
                ['notify.nonb'] = 'No one nearby.',
                ['menu.vending'] = 'Vending Machine',
                ['inf_mapping.use_item'] = 'Use item slot ',
                ['inf_mapping.opn_inv'] = 'Open Inventory',
                ['inf_mapping.tog_slots'] = 'Toggle Hotbar',
            }

            return fallback[key] or key
        end
    }
end
PlayerData = nil
local hotbarShown = false
local isBlurEnabled = true
local lastSlotUse = {}
local SLOT_USE_DEBOUNCE_MS = 450

local function SyncCashItemToHUD(items)
    local cashAmount = 0

    if type(items) == 'table' then
        for _, item in pairs(items) do
            if item and item.name == 'cash' then
                cashAmount = cashAmount + (tonumber(item.amount) or 0)
            end
        end
    end

    TriggerEvent('qb-inventory:client:updateCash', cashAmount)
end


local function ToggleHUD(show)
    if not Config.CustomHUD or not Config.CustomHUD.Enabled then return end

    local resourceName = Config.CustomHUD.ResourceName
    local exportName = Config.CustomHUD.ExportName

    if not resourceName or resourceName == '' then return end
    if not exportName or exportName == '' then return end
    if GetResourceState(resourceName) ~= 'started' then return end

    local ok, err = pcall(function()
        exports[resourceName][exportName](show)
    end)

    if not ok then
        print(('[qb-inventory] CustomHUD export failed: %s:%s -> %s'):format(tostring(resourceName), tostring(exportName), tostring(err)))
    end
end
-- Handlers

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    LocalPlayer.state:set('inv_busy', false, true)
    PlayerData = QBCore.Functions.GetPlayerData()
    GetDrops()
    if PlayerData and PlayerData.items then
        SyncCashItemToHUD(PlayerData.items)
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    LocalPlayer.state:set('inv_busy', true, true)
    PlayerData = nil
end)

RegisterNetEvent('QBCore:Client:UpdateObject', function()
    QBCore = exports['qb-core']:GetCoreObject()

if not Lang then
    Lang = {
        t = function(_, key)
            local fallback = {
                ['notify.nonb'] = 'No one nearby.',
                ['menu.vending'] = 'Vending Machine',
                ['inf_mapping.use_item'] = 'Use item slot ',
                ['inf_mapping.opn_inv'] = 'Open Inventory',
                ['inf_mapping.tog_slots'] = 'Toggle Hotbar',
            }

            return fallback[key] or key
        end
    }
end
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(val)
    PlayerData = val
    if PlayerData and PlayerData.items then
        SyncCashItemToHUD(PlayerData.items)
    end
end)
RegisterNetEvent('QBCore:Player:UpdatePlayerDataField', function(key, val)
    if not PlayerData then
        PlayerData = QBCore.Functions.GetPlayerData()
    end

    if key and val ~= nil then
        PlayerData[key] = val
        if key == 'items' then
            SyncCashItemToHUD(val)
        end
    end
end)


AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        PlayerData = QBCore.Functions.GetPlayerData()
        if PlayerData and PlayerData.items then
            SyncCashItemToHUD(PlayerData.items)
        end
    end
end)

RegisterNetEvent('qb-inventory:client:sendServerTime', function(serverTime)
    SendNUIMessage({
        action = 'setServerTime',
        serverTime = serverTime
    })
end)

-- Functions

function LoadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return end

    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(10)
    end
end

local function DecodeInfoTable(info)
    if type(info) == 'table' then return info end

    if type(info) == 'string' and info ~= '' then
        local ok, decoded = pcall(function()
            return json.decode(info)
        end)

        if ok and type(decoded) == 'table' then
            return decoded
        end
    end

    return {}
end

local function WeaponNameCandidates(name)
    local candidates = {}
    local seen = {}

    local function add(value)
        if type(value) ~= 'string' or value == '' then return end
        if seen[value] then return end
        seen[value] = true
        candidates[#candidates + 1] = value
    end

    add(name)
    if type(name) == 'string' then
        add(string.lower(name))
        add(string.upper(name))
    end

    return candidates
end

local function ComponentToHash(component)
    if component == nil then return nil end

    if type(component) == 'number' then
        return component
    end

    if type(component) == 'string' then
        if component == '' then return nil end

        local numeric = tonumber(component)
        if numeric then return numeric end

        return joaat(component)
    end

    return nil
end

local function ComponentsMatch(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end

    local hashA = ComponentToHash(a)
    local hashB = ComponentToHash(b)

    return hashA ~= nil and hashB ~= nil and hashA == hashB
end

local function GetConfiguredComponent(weapons, weaponName)
    if type(weapons) ~= 'table' then return nil, nil end

    for _, candidate in ipairs(WeaponNameCandidates(weaponName)) do
        if weapons[candidate] then
            return weapons[candidate], candidate
        end
    end

    return nil, nil
end

local function ExtractAttachmentEntries(info)
    local entries = {}
    info = DecodeInfoTable(info)

    local sourceFields = {
        'attachments',
        'attachment',
        'components',
        'component',
        'mods',
        'weaponAttachments',
        'weapon_attachments',
    }

    local function addEntry(key, value)
        if value == nil or value == false then return end

        if type(value) == 'table' then
            local entry = {}
            for k, v in pairs(value) do entry[k] = v end
            entry._key = entry._key or key
            entries[#entries + 1] = entry
            return
        end

        entries[#entries + 1] = {
            _key = key,
            component = value,
            attachment = type(key) == 'string' and key or nil,
        }
    end

    for _, field in ipairs(sourceFields) do
        local source = info[field]
        if type(source) == 'table' then
            for key, value in pairs(source) do
                addEntry(key, value)
            end
        elseif source ~= nil then
            addEntry(field, source)
        end
    end

    -- Extra compatibility for custom weapon shops that place attachment keys directly
    -- inside info instead of inside info.attachments/components.
    for key, value in pairs(info) do
        if key ~= 'attachments' and key ~= 'attachment' and key ~= 'components' and key ~= 'component'
            and key ~= 'mods' and key ~= 'weaponAttachments' and key ~= 'weapon_attachments'
            and key ~= 'serie' and key ~= 'serial' and key ~= 'ammo' and key ~= 'quality'
            and key ~= 'description' and key ~= 'created' and key ~= 'creationDate' and key ~= 'expiryDate' then
            if value == true or type(value) == 'string' or type(value) == 'number' or type(value) == 'table' then
                addEntry(key, value == true and key or value)
            end
        end
    end

    return entries
end

local function ResolveAttachmentKey(attachmentData, weaponName, WeaponAttachments)
    if type(attachmentData) ~= 'table' or type(WeaponAttachments) ~= 'table' then return nil, nil end

    local possibleKeys = {
        attachmentData.attachment,
        attachmentData.item,
        attachmentData.itemName,
        attachmentData.name,
        attachmentData.type,
        attachmentData._key,
    }

    for _, possibleKey in ipairs(possibleKeys) do
        if type(possibleKey) == 'string' and WeaponAttachments[possibleKey] then
            local configuredComponent = GetConfiguredComponent(WeaponAttachments[possibleKey], weaponName)
            if configuredComponent then
                return possibleKey, configuredComponent
            end
        end
    end

    local component = attachmentData.component or attachmentData.hash or attachmentData.componentHash or attachmentData.component_hash or attachmentData.Component

    -- Some weapon shops save the attachment item name directly as the component value.
    if type(component) == 'string' and WeaponAttachments[component] then
        local configuredComponent = GetConfiguredComponent(WeaponAttachments[component], weaponName)
        if configuredComponent then
            return component, configuredComponent
        end
    end

    for attachmentType, weapons in pairs(WeaponAttachments) do
        local configuredComponent = GetConfiguredComponent(weapons, weaponName)
        if configuredComponent then
            if ComponentsMatch(configuredComponent, component) then
                return attachmentType, configuredComponent
            end

            for _, possibleKey in ipairs(possibleKeys) do
                if type(possibleKey) == 'string' and possibleKey == attachmentType then
                    return attachmentType, configuredComponent
                end
            end
        end
    end

    return nil, component
end

local function AddAttachmentResult(results, seen, attachmentKey, component, fallbackLabel)
    if not attachmentKey or seen[attachmentKey] then return end

    local itemInfo = QBCore.Shared.Items[attachmentKey]
    results[#results + 1] = {
        attachment = attachmentKey,
        label = (itemInfo and itemInfo.label) or fallbackLabel or attachmentKey,
        component = component,
    }
    seen[attachmentKey] = true
end

local function AddPedInstalledAttachments(results, seen, itemdata, WeaponAttachments)
    if type(itemdata) ~= 'table' or type(WeaponAttachments) ~= 'table' then return end
    if not itemdata.name then return end

    local ped = PlayerPedId()
    if not ped or ped == 0 then return end

    local weaponHash = joaat(itemdata.name)
    if not HasPedGotWeapon(ped, weaponHash, false) then return end

    for attachmentType, weapons in pairs(WeaponAttachments) do
        local component = GetConfiguredComponent(weapons, itemdata.name)
        local componentHash = ComponentToHash(component)
        if componentHash and HasPedGotWeaponComponent(ped, weaponHash, componentHash) then
            AddAttachmentResult(results, seen, attachmentType, component)
        end
    end
end

local function FormatWeaponAttachments(itemdata)
    if not itemdata or type(itemdata) ~= 'table' then return {} end

    local WeaponAttachments = exports['qb-weapons']:getConfigWeaponAttachments()
    if not WeaponAttachments then return {} end

    local info = DecodeInfoTable(itemdata.info or itemdata.metadata or {})
    local attachmentEntries = ExtractAttachmentEntries(info)
    local attachments = {}
    local seen = {}

    for _, attachmentData in pairs(attachmentEntries) do
        local attachmentKey, component = ResolveAttachmentKey(attachmentData, itemdata.name, WeaponAttachments)
        if attachmentKey then
            AddAttachmentResult(attachments, seen, attachmentKey, component, attachmentData.label)
        elseif Config and Config.Debug then
            print(('[qb-inventory] Attachment metadata was found on %s but could not be matched: %s'):format(tostring(itemdata.name), json.encode(attachmentData)))
        end
    end

    -- Fallback: if a custom/prebuilt weapon shop applied components to the ped but did
    -- not save them under info.attachments, still show what is actually installed on
    -- the currently held weapon.
    AddPedInstalledAttachments(attachments, seen, itemdata, WeaponAttachments)

    return attachments
end

--- @param items string|table - The item(s) to check for. Can be a table of items or a single item as a string.
--- @param amount number [optional] - The minimum amount required for each item. If not provided, any amount greater than 0 will be considered.
--- @return boolean - Returns true if the player has the item(s) with the specified amount, false otherwise.
function HasItem(items, amount)
    if not PlayerData or not PlayerData.items then
        return false
    end
    local requiredItems = {}
    if type(items) ~= 'table' then
        requiredItems[items] = amount or 1
    else
        if table.type(items) == 'array' then
            for _, itemName in ipairs(items) do
                requiredItems[itemName] = amount or 1
            end
        else -- Map
            for itemName, itemAmount in pairs(items) do
                requiredItems[itemName] = itemAmount
            end
        end
    end
    if not next(requiredItems) then
        return true
    end
    local playerItemCounts = {}
    for _, itemData in pairs(PlayerData.items) do
        if itemData and itemData.name and itemData.amount then
            playerItemCounts[itemData.name] = (playerItemCounts[itemData.name] or 0) + itemData.amount
        end
    end
    for itemName, requiredAmount in pairs(requiredItems) do
        if (playerItemCounts[itemName] or 0) < requiredAmount then
            return false
        end
    end
    return true
end

exports('HasItem', HasItem)
-- Events

RegisterNetEvent('qb-inventory:client:requiredItems', function(items, bool)
    local itemTable = {}
    if bool then
        for k in pairs(items) do
            itemTable[#itemTable + 1] = {
                item = items[k].name,
                label = QBCore.Shared.Items[items[k].name]['label'],
                image = items[k].image,
            }
        end
    end

    SendNUIMessage({
        action = 'requiredItem',
        items = itemTable,
        toggle = bool
    })
end)

RegisterNetEvent('qb-inventory:client:hotbar', function(items)
    hotbarShown = not hotbarShown
    SendNUIMessage({
        action = 'toggleHotbar',
        open = hotbarShown,
        items = items
    })
end)

RegisterNetEvent('qb-inventory:client:closeInv', function()
    ToggleHUD(true)
    SendNUIMessage({
        action = 'close',
    })
end)

RegisterNetEvent('qb-inventory:client:updateInventory', function()
    local items = {}
    if PlayerData and type(PlayerData.items) == "table" then
        items = PlayerData.items
    end

    SyncCashItemToHUD(items)

    SendNUIMessage({
        action = 'update',
        inventory = items
    })
end)

RegisterNetEvent('qb-inventory:client:ItemBox', function(itemData, type, amount)
   -- print(('DEBUG: Received ItemBox event with item: %s'):format(json.encode(itemData)))

    SendNUIMessage({
        action = 'itemBox',
        item = itemData,
        type = type,
        amount = amount
    })
end)

RegisterNetEvent('qb-inventory:server:RobPlayer', function(TargetId)
    SendNUIMessage({
        action = 'RobMoney',
        TargetId = TargetId,
    })
end)

RegisterNetEvent('qb-inventory:client:openInventory', function(items, other)
    ToggleHUD(false)
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        inventory = items,
        slots = Config.MaxSlots,
        maxweight = Config.MaxWeight,
        other = other
    })
end)

RegisterNetEvent('qb-inventory:client:giveAnim', function()
    if IsPedInAnyVehicle(PlayerPedId(), false) then return end
    LoadAnimDict('mp_common')
    TaskPlayAnim(PlayerPedId(), 'mp_common', 'givetake1_b', 8.0, 1.0, -1, 16, 0, false, false, false)
end)

-- NUI Callbacks

RegisterNUICallback('PlayDropFail', function(_, cb)
    PlaySound(-1, 'Place_Prop_Fail', 'DLC_Dmod_Prop_Editor_Sounds', 0, 0, 1)
    cb('ok')
end)

RegisterNUICallback('AttemptPurchase', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-inventory:server:attemptPurchase', function(canPurchase)
        cb(canPurchase)
    end, data)
end)

RegisterNUICallback('CloseInventory', function(data, cb)
    ToggleHUD(true)
    SetNuiFocus(false, false)
    TriggerScreenblurFadeOut(250)

    if data.name then
        if data.name:find('trunk-') then
            CloseTrunk()
        end
        TriggerServerEvent('qb-inventory:server:closeInventory', data.name)
    elseif CurrentDrop then
        TriggerServerEvent('qb-inventory:server:closeInventory', CurrentDrop)
        CurrentDrop = nil
    end
    cb('ok')
end)

RegisterNUICallback('SetBlur', function(data, cb)
    isBlurEnabled = data.enabled
    if isBlurEnabled then
        TriggerScreenblurFadeIn(250)
    else
        TriggerScreenblurFadeOut(250)
    end
    cb('ok')
end)

RegisterNUICallback('ToggleBlur', function(data, cb)
    isBlurEnabled = data.enabled
    if isBlurEnabled then
        TriggerScreenblurFadeIn(250)
    else
        TriggerScreenblurFadeOut(250)
    end
    cb('ok')
end)

RegisterNUICallback('UseItem', function(data, cb)
    TriggerServerEvent('qb-inventory:server:useItem', data.item)
    cb('ok')
end)

RegisterNUICallback('SetInventoryData', function(data, cb)
    TriggerServerEvent('qb-inventory:server:SetInventoryData', data.fromInventory, data.toInventory, data.fromSlot, data.toSlot, data.fromAmount, data.toAmount)
    cb('ok')
end)

-- RealitySucksRP legacy UI compatibility: the custom UI posts GiveItem directly.
RegisterNUICallback('GiveItem', function(data, cb)
    local player, distance = QBCore.Functions.GetClosestPlayer(GetEntityCoords(PlayerPedId()))
    if player ~= -1 and distance < 3 then
        local playerId = GetPlayerServerId(player)
        QBCore.Functions.TriggerCallback('qb-inventory:server:giveItem', function(success)
            cb(success)
        end, playerId, data.item.name, data.amount, data.slot, data.info)
    else
        QBCore.Functions.Notify(Lang:t('notify.nonb'), 'error')
        cb(false)
    end
end)

RegisterNUICallback('GetWeaponData', function(cData, cb)
    local data = {
        WeaponData = QBCore.Shared.Items[cData.weapon],
        AttachmentData = FormatWeaponAttachments(cData.ItemData)
    }
    cb(data)
end)

RegisterNUICallback('RemoveAttachment', function(data, cb)
    local ped = PlayerPedId()
    local WeaponData = data and data.WeaponData
    local AttachmentData = data and data.AttachmentData

    if not WeaponData or not WeaponData.name or not AttachmentData or not AttachmentData.attachment then
        cb({ ok = false, error = 'missing_attachment_data' })
        return
    end

    local allAttachments = exports['qb-weapons']:getConfigWeaponAttachments()
    local attachmentKey = AttachmentData.attachment
    local weaponAttachments = allAttachments and allAttachments[attachmentKey]

    -- Compatibility for servers that accidentally save weapon_suppressor while items.lua uses suppressor_attachment.
    if (not weaponAttachments or not GetConfiguredComponent(weaponAttachments, WeaponData.name)) and attachmentKey == 'weapon_suppressor' then
        if allAttachments and allAttachments['suppressor_attachment'] then
            attachmentKey = 'suppressor_attachment'
            AttachmentData.attachment = 'suppressor_attachment'
            weaponAttachments = allAttachments['suppressor_attachment']
        end
    end

    -- Extra fallback: if the panel sent only a component/hash, resolve it back to the qb-weapons item key.
    if (not weaponAttachments or not GetConfiguredComponent(weaponAttachments, WeaponData.name)) and AttachmentData.component then
        local resolvedKey = ResolveAttachmentKey(AttachmentData, WeaponData.name, allAttachments)
        if resolvedKey and allAttachments[resolvedKey] then
            attachmentKey = resolvedKey
            AttachmentData.attachment = resolvedKey
            weaponAttachments = allAttachments[resolvedKey]
        end
    end

    local Attachment = GetConfiguredComponent(weaponAttachments, WeaponData.name)
    local itemInfo = QBCore.Shared.Items[attachmentKey]

    if not Attachment then
        print(('[qb-inventory] RemoveAttachment blocked: no component for %s on %s'):format(tostring(attachmentKey), tostring(WeaponData.name)))
        cb({ ok = false, error = 'missing_component', Attachments = FormatWeaponAttachments(WeaponData), WeaponData = WeaponData })
        return
    end

    if not itemInfo then
        print(('[qb-inventory] RemoveAttachment blocked: missing QBCore.Shared.Items entry for %s'):format(tostring(attachmentKey)))
        cb({ ok = false, error = 'missing_item', Attachments = FormatWeaponAttachments(WeaponData), WeaponData = WeaponData })
        return
    end

    QBCore.Functions.TriggerCallback('qb-weapons:server:RemoveAttachment', function(NewAttachments)
        if NewAttachments ~= false then
            local Attachies = {}

            -- Keep the weapon data returned to NUI in sync with qb-weapons after detach.
            WeaponData.info = WeaponData.info or {}
            WeaponData.info.attachments = NewAttachments or {}

            RemoveWeaponComponentFromPed(ped, joaat(WeaponData.name), ComponentToHash(Attachment) or joaat(Attachment))
            for _, v in pairs(NewAttachments or {}) do
                for attachmentType, weapons in pairs(allAttachments or {}) do
                    local componentHash = GetConfiguredComponent(weapons, WeaponData.name)
                    if componentHash and ComponentsMatch(v.component, componentHash) then
                        local labelItem = QBCore.Shared.Items[attachmentType] or QBCore.Shared.Items[attachmentKey]
                        Attachies[#Attachies + 1] = {
                            attachment = attachmentType,
                            label = (labelItem and labelItem.label) or attachmentType,
                            component = componentHash,
                        }
                    end
                end
            end
            cb({ ok = true, Attachments = Attachies, WeaponData = WeaponData, itemInfo = itemInfo })
        else
            cb({ ok = false, error = 'server_rejected', Attachments = FormatWeaponAttachments(WeaponData), WeaponData = WeaponData })
        end
    end, AttachmentData, WeaponData)
end)

RegisterNUICallback('GetNearbyPlayers', function(_, cb)
    local nearbyPlayers = {}
    local playersInRadius = QBCore.Functions.GetPlayersFromCoords(GetEntityCoords(PlayerPedId()), 5.0) 

    for _, pId in ipairs(playersInRadius) do
        if pId ~= PlayerId() then 
            table.insert(nearbyPlayers, { id = GetPlayerServerId(pId), name = GetPlayerName(pId) })
        end
    end
    
    cb(nearbyPlayers)
end)

RegisterNUICallback('GiveItemToTarget', function(data, cb)
    if not data or not data.targetId then
        cb(false)
        return
    end
    QBCore.Functions.TriggerCallback('qb-inventory:server:giveItem', function(success)
        cb(success)
    end, data) 
end)

RegisterNUICallback('Notify', function(data, cb)
    if not data.message or not data.type then return end
    QBCore.Functions.Notify(data.message, data.type, data.duration or 5000)
    cb('ok')
end)

-- Vending

CreateThread(function()
    exports['qb-target']:AddTargetModel(Config.VendingObjects, {
        options = {
            {
                type = 'server',
                event = 'qb-inventory:server:openVending',
                icon = 'fa-solid fa-cash-register',
                label = Lang:t('menu.vending'),
            },
        },
        distance = 2.5
    })
end)

-- Commands

RegisterCommand('openInv', function()
    if IsNuiFocused() or IsPauseMenuActive() then return end
    ExecuteCommand('inventory')
end, false)

RegisterCommand('toggleHotbar', function()
    ExecuteCommand('hotbar')
end, false)

for i = 1, 5 do
    RegisterCommand('slot_' .. i, function()
        local now = GetGameTimer()
        if lastSlotUse[i] and (now - lastSlotUse[i]) < SLOT_USE_DEBOUNCE_MS then return end
        lastSlotUse[i] = now

        if not PlayerData or not PlayerData.items then return end
        local itemData = PlayerData.items[i]
        if not itemData then return end
        if itemData.type == "weapon" then
            if HoldingDrop then
                return QBCore.Functions.Notify("Your already holding a bag, Go Drop it!", "error", 5500)
            end
        end
        TriggerServerEvent('qb-inventory:server:useItem', itemData)
    end, false)
    RegisterKeyMapping('slot_' .. i, Lang:t('inf_mapping.use_item') .. i, 'keyboard', i)
end

RegisterKeyMapping('openInv', Lang:t('inf_mapping.opn_inv'), 'keyboard', Config.Keybinds.Open)
RegisterKeyMapping('toggleHotbar', Lang:t('inf_mapping.tog_slots'), 'keyboard', Config.Keybinds.Hotbar)

exports('ToggleHotbar', function(state)
    isHotbarDisabled = state
end)

-- =================================================================
--                        PLAYER SEARCH FEATURE (ROB)
-- =================================================================

CreateThread(function()
    while not exports['qb-target'] do Wait(100) end
    
    exports['qb-target']:AddTargetEntity(GetGamePool('CPed'), {
        options = {
            {
                icon = 'fa-solid fa-person-circle-question',
                label = 'Search Player',
                action = function(entity)
                    local targetServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))
                    if targetServerId ~= -1 then
                        TriggerServerEvent('robbery:server:initiateRob', targetServerId)
                    end
                end,
                canInteract = function(entity)
                    if not IsPedAPlayer(entity) then
                        return false
                    end
                    local targetServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))
                    if targetServerId == GetPlayerServerId(PlayerId()) then
                        return false
                    end
                    local isDead = IsPedDeadOrDying(entity, 1)
                    local isHandsUp = IsEntityPlayingAnim(entity, 'missminuteman_1ig_2', 'handsup_base', 3)
                    
                    return isDead or isHandsUp
                end,
            }
        },
        distance = 2.0
    })
end)

RegisterNetEvent('qb-inventory:client:beingRobbed', function()
    local playerPed = PlayerPedId()
    if not IsPedDeadOrDying(playerPed, 1) then
        local duration = 5500
        local timer = 0
        
        local animDict = 'missminuteman_1ig_2'
        RequestAnimDict(animDict)
        while not HasAnimDictLoaded(animDict) do
            Wait(10)
        end
        QBCore.Functions.Notify('Someone is searching you! Don\'t move!', 'warn', duration)
        CreateThread(function()
            while timer < duration do
                if not IsEntityPlayingAnim(playerPed, animDict, 'handsup_base', 3) then
                    TaskPlayAnim(playerPed, animDict, "handsup_base", 8.0, -8.0, -1, 49, 0, false, false, false)
                end
                timer = timer + 100
                Wait(100)
            end
        end)
    end
end)

RegisterCommand('rob', function(source, args, rawCommand)
    local closestPlayer, closestDistance = QBCore.Functions.GetClosestPlayer()
    if closestPlayer == -1 or closestDistance > 2.5 then
        QBCore.Functions.Notify('No one nearby to rob.', 'error')
        return
    end
    local targetServerId = GetPlayerServerId(closestPlayer)
    TriggerServerEvent('robbery:server:initiateRob', targetServerId)
end, false)

RegisterNetEvent('robbery:client:startRobberyProgress', function(targetServerId)
    QBCore.Functions.Progressbar('player_robbery', 'Searching Person...', 5000, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'random@arrests',
        anim = 'busted_search',
        flags = 49, 
    }, {}, {}, function() 
        StopAnimTask(PlayerPedId(), 'random@arrests', 'busted_search', 1.0)
        TriggerServerEvent('qb-inventory:server:robPlayer', targetServerId)
    end, function()
        StopAnimTask(PlayerPedId(), 'random@arrests', 'busted_search', 1.0)
        QBCore.Functions.Notify('Action canceled', 'error')
    end)
end)

RegisterNetEvent('robbery:client:checkIfHandsUp', function(robberServerId)
    local playerPed = PlayerPedId()
    local isHandsUp = IsEntityPlayingAnim(playerPed, 'missminuteman_1ig_2', 'handsup_base', 3)
    TriggerServerEvent('robbery:server:handsUpResult', robberServerId, isHandsUp)
end)