-- client/drops.lua

HoldingDrop = false
local bagObject = nil
local heldDrop = nil
CurrentDrop = nil

local function ResolveDropEntity(netId, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 2500)

    while GetGameTimer() < deadline and not NetworkDoesNetworkIdExist(netId) do
        Wait(10)
    end
    if not NetworkDoesNetworkIdExist(netId) then return nil end

    local bag = NetworkGetEntityFromNetworkId(netId)
    while GetGameTimer() < deadline and not DoesEntityExist(bag) do
        Wait(10)
        bag = NetworkGetEntityFromNetworkId(netId)
    end

    if not DoesEntityExist(bag) then return nil end
    return bag
end

local function PrepareDropEntity(netId)
    CreateThread(function()
        local bag = ResolveDropEntity(netId, 5000)
        if not bag then return end

        SetEntityAsMissionEntity(bag, true, true)
        PlaceObjectOnGroundProperly(bag)
        FreezeEntityPosition(bag, true)
    end)
end

-- Functions

function GetDrops()
    QBCore.Functions.TriggerCallback('qb-inventory:server:GetCurrentDrops', function(drops)
        if not drops then return end
        for k, v in pairs(drops) do
            local bag = NetworkGetEntityFromNetworkId(v.entityId)
            if DoesEntityExist(bag) then
                exports['qb-target']:AddTargetEntity(bag, {
                    options = {
                        {
                            icon = 'fas fa-backpack',
                            label = Lang:t('menu.o_bag'),
                            action = function()
                                TriggerServerEvent('qb-inventory:server:openDrop', k)
                                CurrentDrop = k
                            end,
                        },
                    },
                    distance = 2.5,
                })
            end
        end
    end)
end

-- Events

RegisterNetEvent('qb-inventory:client:removeDropTarget', function(dropId)
    local bag = ResolveDropEntity(dropId, 2500)
    if not bag then return end
    exports['qb-target']:RemoveTargetEntity(bag)
end)

RegisterNetEvent('qb-inventory:client:setupDropTarget', function(dropId)
    local bag = ResolveDropEntity(dropId, 10000)
    if not bag then return end
    local newDropId = 'drop-' .. dropId
    exports['qb-target']:AddTargetEntity(bag, {
        options = {
            {
                icon = 'fas fa-backpack',
                label = Lang:t('menu.o_bag'),
                action = function()
                    TriggerServerEvent('qb-inventory:server:openDrop', newDropId)
                    CurrentDrop = newDropId
                end,
            },
            {
                icon = 'fas fa-hand-pointer',
                label = 'Pick up bag',
                action = function()
                    if IsPedArmed(PlayerPedId(), 4) then
                        return QBCore.Functions.Notify("You can not be holding a Gun and a Bag!", "error", 5500)
                    end
                    if HoldingDrop then
                        return QBCore.Functions.Notify("Your already holding a bag, Go Drop it!", "error", 5500)
                    end
                    QBCore.Functions.TriggerCallback('qb-inventory:server:pickupDrop', function(allowed)
                        if not allowed then
                            return QBCore.Functions.Notify("You can not pick up that bag.", "error", 3500)
                        end
                        if HoldingDrop then return end
                        AttachEntityToEntity(
                            bag,
                            PlayerPedId(),
                            GetPedBoneIndex(PlayerPedId(), Config.ItemDropObjectBone),
                            Config.ItemDropObjectOffset[1].x,
                            Config.ItemDropObjectOffset[1].y,
                            Config.ItemDropObjectOffset[1].z,
                            Config.ItemDropObjectOffset[2].x,
                            Config.ItemDropObjectOffset[2].y,
                            Config.ItemDropObjectOffset[2].z,
                            true, true, false, true, 1, true
                        )
                        bagObject = bag
                        HoldingDrop = true
                        heldDrop = newDropId
                        exports['qb-core']:DrawText('Press [G] to drop the bag')
                    end, newDropId)
                end,
            }
        },
        distance = 2.5,
    })
end)

-- NUI Callbacks

RegisterNUICallback('DropItemFromUI', function(item, cb)
    QBCore.Functions.TriggerCallback('qb-inventory:server:createDrop', function(responseData)
        if responseData and responseData.netId then
            -- Return the server-authoritative player + drop inventories first.
            -- Entity placement is visual work and must never hold the NUI callback open.
            cb(responseData)
            PrepareDropEntity(responseData.netId)
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
            cb(responseData.dropData and responseData.dropData.name or ('drop-' .. netId))
            PrepareDropEntity(netId)
        else
            cb(false)
        end
    end, item)
end)

-- Thread

CreateThread(function()
    while true do
        -- Only poll per frame while a bag is actually in hand.
        if not HoldingDrop then
            Wait(500)
            goto continue
        end

        Wait(0)
        if IsControlJustPressed(0, 47) then
            local playerPed = PlayerPedId()
            if IsPedInAnyVehicle(playerPed, false) then
                QBCore.Functions.Notify("You cannot drop a bag while in a vehicle.", "error", 3500)
            else
                DetachEntity(bagObject, true, true)
                local coords = GetEntityCoords(playerPed)
                local forward = GetEntityForwardVector(playerPed)
                local x, y, z = table.unpack(coords + forward * 0.57)
                SetEntityCoords(bagObject, x, y, z - 0.9, false, false, false, false)
                FreezeEntityPosition(bagObject, true)
                exports['qb-core']:HideText()
                TriggerServerEvent('qb-inventory:server:updateDrop', heldDrop, coords)
                HoldingDrop = false
                bagObject = nil
                heldDrop = nil
            end
        end

        ::continue::
    end
end)