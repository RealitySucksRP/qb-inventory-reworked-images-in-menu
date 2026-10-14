-- client/drops.lua

HoldingDrop = false
CurrentDrop = nil

local bagObject = nil
local heldDrop = nil
local dropRegistry = {}      -- [dropName] = netId, survives out-of-scope streaming
local targetedEntities = {}  -- [netId] = local entity handle currently registered

local function ResolveDropEntity(netId, timeoutMs)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return nil end

    local deadline = GetGameTimer() + (timeoutMs or 2500)
    while GetGameTimer() < deadline and not NetworkDoesNetworkIdExist(netId) do Wait(25) end
    if not NetworkDoesNetworkIdExist(netId) then return nil end

    local bag = NetworkGetEntityFromNetworkId(netId)
    while GetGameTimer() < deadline and not DoesEntityExist(bag) do
        Wait(25)
        bag = NetworkGetEntityFromNetworkId(netId)
    end
    if not DoesEntityExist(bag) then return nil end
    return bag
end

local function AddDropTarget(dropName, netId, bag)
    if heldDrop == dropName then return end
    if targetedEntities[netId] == bag and DoesEntityExist(bag) then return end

    exports['qb-target']:AddTargetEntity(bag, {
        options = {
            {
                icon = 'fas fa-backpack',
                label = Lang:t('menu.o_bag'),
                action = function()
                    TriggerServerEvent('qb-inventory:server:openDrop', dropName)
                    CurrentDrop = dropName
                end,
            },
            {
                icon = 'fas fa-hand-pointer',
                label = 'Pick up bag',
                action = function()
                    if IsPedArmed(PlayerPedId(), 4) then
                        return QBCore.Functions.Notify('You can not be holding a Gun and a Bag!', 'error', 5500)
                    end
                    if HoldingDrop then
                        return QBCore.Functions.Notify('Your already holding a bag, Go Drop it!', 'error', 5500)
                    end

                    QBCore.Functions.TriggerCallback('qb-inventory:server:pickupDrop', function(allowed)
                        if not allowed then
                            return QBCore.Functions.Notify('You can not pick up that bag.', 'error', 3500)
                        end
                        local playerPed = PlayerPedId()
                        if HoldingDrop or not DoesEntityExist(bag) or IsEntityDead(playerPed) then
                            local coords = GetEntityCoords(playerPed)
                            TriggerServerEvent('qb-inventory:server:updateDrop', dropName, {
                                x = coords.x, y = coords.y, z = coords.z
                            })
                            return
                        end

                        HoldingDrop = true
                        heldDrop = dropName
                        bagObject = bag
                        FreezeEntityPosition(bag, false)
                        exports['qb-target']:RemoveTargetEntity(bag)
                        targetedEntities[netId] = nil

                        AttachEntityToEntity(
                            bag,
                            playerPed,
                            GetPedBoneIndex(playerPed, Config.ItemDropObjectBone),
                            Config.ItemDropObjectOffset[1].x,
                            Config.ItemDropObjectOffset[1].y,
                            Config.ItemDropObjectOffset[1].z,
                            Config.ItemDropObjectOffset[2].x,
                            Config.ItemDropObjectOffset[2].y,
                            Config.ItemDropObjectOffset[2].z,
                            true, true, false, true, 1, true
                        )

                        if not IsEntityAttachedToEntity(bag, playerPed) then
                            local coords = GetEntityCoords(playerPed)
                            HoldingDrop = false
                            heldDrop = nil
                            bagObject = nil
                            TriggerServerEvent('qb-inventory:server:updateDrop', dropName, {
                                x = coords.x, y = coords.y, z = coords.z
                            })
                            RegisterDropReference(dropName, netId)
                            return
                        end

                        exports['qb-core']:DrawText('Press [G] to drop the bag')
                    end, dropName)
                end,
            }
        },
        distance = 2.5,
    })
    targetedEntities[netId] = bag
end

local function RegisterDropReference(dropName, netId)
    if type(dropName) ~= 'string' then return end
    netId = tonumber(netId)
    if not netId or netId <= 0 then return end
    dropRegistry[dropName] = netId

    local bag = ResolveDropEntity(netId, 150)
    if bag then AddDropTarget(dropName, netId, bag) end
end

local function RemoveDropReference(netId)
    netId = tonumber(netId)
    if not netId then return end

    for dropName, registeredNetId in pairs(dropRegistry) do
        if registeredNetId == netId then
            if heldDrop == dropName then
                HoldingDrop = false
                heldDrop = nil
                bagObject = nil
                exports['qb-core']:HideText()
            end
            if CurrentDrop == dropName then CurrentDrop = nil end
            dropRegistry[dropName] = nil
        end
    end

    local bag = targetedEntities[netId]
    if bag and DoesEntityExist(bag) then exports['qb-target']:RemoveTargetEntity(bag) end
    targetedEntities[netId] = nil
end

local function PrepareDropEntity(dropName, netId)
    RegisterDropReference(dropName, netId)
    CreateThread(function()
        local bag = ResolveDropEntity(netId, 5000)
        if not bag then return end
        SetEntityAsMissionEntity(bag, true, true)
        PlaceObjectOnGroundProperly(bag)
        FreezeEntityPosition(bag, true)
        AddDropTarget(dropName, tonumber(netId), bag)
    end)
end

function GetDrops()
    QBCore.Functions.TriggerCallback('qb-inventory:server:GetCurrentDrops', function(drops)
        if type(drops) ~= 'table' then return end
        for dropName, drop in pairs(drops) do
            if drop and drop.entityId then RegisterDropReference(dropName, drop.entityId) end
        end
    end)
end

RegisterNetEvent('qb-inventory:client:removeDropTarget', function(netId)
    RemoveDropReference(netId)
end)

RegisterNetEvent('qb-inventory:client:setupDropTarget', function(netId)
    netId = tonumber(netId)
    if not netId then return end
    RegisterDropReference('drop-' .. netId, netId)
end)

RegisterNUICallback('DropItemFromUI', function(item, cb)
    QBCore.Functions.TriggerCallback('qb-inventory:server:createDrop', function(responseData)
        if responseData and responseData.netId then
            cb(responseData)
            local dropName = responseData.dropData and responseData.dropData.name or ('drop-' .. responseData.netId)
            PrepareDropEntity(dropName, responseData.netId)
        else
            cb(false)
        end
    end, item)
end)

-- RealitySucksRP legacy UI compatibility. Older UIs expect only dropData.
RegisterNUICallback('DropItem', function(item, cb)
    QBCore.Functions.TriggerCallback('qb-inventory:server:createDrop', function(responseData)
        if responseData and responseData.netId then
            local netId = responseData.netId
            local dropName = responseData.dropData and responseData.dropData.name or ('drop-' .. netId)
            cb(dropName)
            PrepareDropEntity(dropName, netId)
        else
            cb(false)
        end
    end, item)
end)

-- Reconcile network entities as they stream in. GetCurrentDrops seeds opaque
-- net-id references for every live bag; routing-bucket/distance authority remains
-- server-side and qb-target is attached only when the entity actually streams in.
CreateThread(function()
    while true do
        Wait(1500)
        for dropName, netId in pairs(dropRegistry) do
            if heldDrop ~= dropName then
                local tracked = targetedEntities[netId]
                if tracked and not DoesEntityExist(tracked) then
                    targetedEntities[netId] = nil
                    tracked = nil
                end
                if not tracked and NetworkDoesNetworkIdExist(netId) then
                    local bag = NetworkGetEntityFromNetworkId(netId)
                    if DoesEntityExist(bag) then AddDropTarget(dropName, netId, bag) end
                end
            end
        end
    end
end)

local function ReleaseHeldDrop()
    if not HoldingDrop or not heldDrop then return false end

    local playerPed = PlayerPedId()
    if not bagObject or not DoesEntityExist(bagObject) then
        local coords = GetEntityCoords(playerPed)
        TriggerServerEvent('qb-inventory:server:updateDrop', heldDrop, { x = coords.x, y = coords.y, z = coords.z })
        HoldingDrop = false
        heldDrop = nil
        bagObject = nil
        exports['qb-core']:HideText()
        return true
    end

    local dropName = heldDrop
    local netId = dropRegistry[dropName]
    DetachEntity(bagObject, true, true)

    local coords = GetEntityCoords(playerPed)
    local forward = GetEntityForwardVector(playerPed)
    local x, y, z = table.unpack(coords + forward * 0.57)
    SetEntityCoords(bagObject, x, y, z - 0.9, false, false, false, false)
    PlaceObjectOnGroundProperly(bagObject)
    FreezeEntityPosition(bagObject, true)
    exports['qb-core']:HideText()
    TriggerServerEvent('qb-inventory:server:updateDrop', dropName, {
        x = coords.x, y = coords.y, z = coords.z
    })

    HoldingDrop = false
    heldDrop = nil
    bagObject = nil

    if netId then
        local bag = ResolveDropEntity(netId, 250)
        if bag then AddDropTarget(dropName, netId, bag) end
    end
    return true
end

RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    local metadata = data and data.metadata or {}
    if HoldingDrop and (metadata.isdead or metadata.inlaststand) then
        ReleaseHeldDrop()
    end
end)

CreateThread(function()
    while true do
        if not HoldingDrop then
            Wait(500)
            goto continue
        end

        Wait(0)
        if IsControlJustPressed(0, 47) then
            local playerPed = PlayerPedId()
            if IsPedInAnyVehicle(playerPed, false) then
                QBCore.Functions.Notify('You cannot drop a bag while in a vehicle.', 'error', 3500)
            elseif heldDrop then
                ReleaseHeldDrop()
            end
        end

        ::continue::
    end
end)

local function CleanupDropClientState()
    if bagObject and DoesEntityExist(bagObject) and IsEntityAttached(bagObject) then
        DetachEntity(bagObject, true, true)
        FreezeEntityPosition(bagObject, true)
    end
    exports['qb-core']:HideText()

    for netId, entity in pairs(targetedEntities) do
        if entity and DoesEntityExist(entity) then
            exports['qb-target']:RemoveTargetEntity(entity)
        end
        targetedEntities[netId] = nil
    end

    HoldingDrop = false
    bagObject = nil
    heldDrop = nil
    CurrentDrop = nil
    dropRegistry = {}
end

RegisterNetEvent('QBCore:Client:OnPlayerUnload', CleanupDropClientState)
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then CleanupDropClientState() end
end)
