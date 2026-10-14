---------------------------
-- server/commands.lua
---------------------------

QBCore.Commands.Add('giveitem', 'Give An Item (Admin Only)', { { name = 'id', help = 'Player ID' }, { name = 'item', help = 'Name of the item (not a label)' }, { name = 'amount', help = 'Amount of items' } }, false, function(source, args)
    local id = tonumber(args[1])
    local player = QBCore.Functions.GetPlayer(id)
    local itemName = tostring(args[2]):lower()
    local amount = tonumber(args[3]) or 1
    if itemName == (Config.CashItemName or 'cash') then
        QBCore.Functions.Notify(source, ('Spawning "%s" as an item is not allowed. Use /givemoney instead.'):format(Config.CashItemName or 'cash'), 'error', 7500)
        return
    end

    local itemData = QBCore.Shared.Items[itemName]
    if player then
        if itemData then
            local info = {}
            if itemData['name'] == 'id_card' then
                info.citizenid = player.PlayerData.citizenid
                info.firstname = player.PlayerData.charinfo.firstname
                info.lastname = player.PlayerData.charinfo.lastname
                info.birthdate = player.PlayerData.charinfo.birthdate
                info.gender = player.PlayerData.charinfo.gender
                info.nationality = player.PlayerData.charinfo.nationality
            elseif itemData['name'] == 'driver_license' then
                info.firstname = player.PlayerData.charinfo.firstname
                info.lastname = player.PlayerData.charinfo.lastname
                info.birthdate = player.PlayerData.charinfo.birthdate
                info.type = 'Class C Driver License'
            elseif itemData['type'] == 'weapon' then
                amount = 1
                info.serie = tostring(QBCore.Shared.RandomInt(2) .. QBCore.Shared.RandomStr(3) .. QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2) .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(4))
                info.quality = 100
            elseif itemData['name'] == 'harness' then
                info.uses = 20
            elseif itemData['name'] == 'markedbills' then
                info.worth = math.random(5000, 10000)
            elseif itemData['name'] == 'printerdocument' then
                info.url = Config.DefaultPrinterDocumentUrl or ''
            end

            if AddItem(id, itemData['name'], amount, false, info, 'give item command') then
    QBCore.Functions.Notify(source, Lang:t('notify.yhg') .. GetPlayerName(id) .. ' ' .. amount .. ' ' .. itemData['name'] .. '', 'success')
    local targetPlayerObject = Player(id)
    if targetPlayerObject and targetPlayerObject.state.inv_busy then
        TriggerClientEvent('qb-inventory:client:updateInventory', id, player.PlayerData.items)
    end
else
                QBCore.Functions.Notify(source, Lang:t('notify.cgitem'), 'error')
            end
        else
            QBCore.Functions.Notify(source, Lang:t('notify.idne'), 'error')
        end
    else
        QBCore.Functions.Notify(source, Lang:t('notify.pdne'), 'error')
    end
end, 'admin')

QBCore.Commands.Add('randomitems', 'Receive random items', {}, false, function(source)
    local player = QBCore.Functions.GetPlayer(source)
    local playerInventory = player.PlayerData.items
    local filteredItems = {}
    local cashItemName = (Config.CashItemName or 'cash'):lower()
    for k, v in pairs(QBCore.Shared.Items) do
        if QBCore.Shared.Items[k]['type'] ~= 'weapon' and tostring(v.name):lower() ~= cashItemName then
            filteredItems[#filteredItems + 1] = v
        end
    end
    for _ = 1, 10, 1 do
        local randitem = filteredItems[math.random(1, #filteredItems)]
        local amount = math.random(1, 10)
        if randitem['unique'] then
            amount = 1
        end
        local emptySlot = nil
        for i = 1, Config.MaxSlots do
            if not playerInventory[i] then
                emptySlot = i
                break
            end
        end
        if emptySlot then
            if AddItem(source, randitem.name, amount, emptySlot, false, 'random items command') then
                player = QBCore.Functions.GetPlayer(source)
                playerInventory = player.PlayerData.items
                if Player(source).state.inv_busy then TriggerClientEvent('qb-inventory:client:updateInventory', source, player.PlayerData.items) end
            end
            Wait(1000)
        end
    end
end, 'god')

QBCore.Commands.Add('clearinv', 'Clear Inventory (Admin Only)', { { name = 'id', help = 'Player ID' } }, false, function(source, args)
    local id = tonumber(args[1])
    if not id then
        ClearInventory(source)
        return
    end
    ClearInventory(id)
end, 'admin')

-- Keybindings

RegisterCommand('closeInv', function(source)
    CloseInventory(source)
end, false)

RegisterCommand('hotbar', function(source)
    if IsInventoryServerBusy(source) then return end
    local QBPlayer = QBCore.Functions.GetPlayer(source)
    if not QBPlayer then return end
    if not QBPlayer or QBPlayer.PlayerData.metadata['isdead'] or QBPlayer.PlayerData.metadata['inlaststand'] or QBPlayer.PlayerData.metadata['ishandcuffed'] then return end
    local hotbarItems = {
        QBPlayer.PlayerData.items[1],
        QBPlayer.PlayerData.items[2],
        QBPlayer.PlayerData.items[3],
        QBPlayer.PlayerData.items[4],
        QBPlayer.PlayerData.items[5],
    }
    TriggerClientEvent('qb-inventory:client:hotbar', source, hotbarItems)
end, false)

-- Vehicle inventory authority.
--
-- The client is allowed to *request* a vehicle inventory but not to choose its
-- identity, capacity or session lifetime. The server resolves the networked
-- vehicle, plate, routing bucket and QBCore shared-vehicle category itself.
local VEHICLE_CATEGORY_CLASS = {
    compacts = 0, sedans = 1, suvs = 2, coupes = 3, muscle = 4,
    sportsclassics = 5, sports = 6, super = 7, motorcycles = 8,
    offroad = 9, industrial = 10, utility = 11, vans = 12, cycles = 13,
    boats = 14, helicopters = 15, planes = 16, service = 17,
    emergency = 18, military = 19, commercial = 20, trains = 21,
    openwheel = 22,
}

local VEHICLE_MODEL_OVERRIDES = {}
for modelName, limits in pairs(VehicleStorage.byModel or {}) do
    VEHICLE_MODEL_OVERRIDES[joaat(modelName)] = limits
end

local function TrimPlate(value)
    if type(value) ~= 'string' then return nil end
    return value:gsub('^%s+', ''):gsub('%s+$', '')
end

local function VerifyVehicleInventory(src, inventory, netId)
    if type(inventory) ~= 'string' then return false end

    local prefix = inventory:match('^(trunk)%-') or inventory:match('^(glovebox)%-')
    if not prefix then return false end

    netId = tonumber(netId)
    if not netId or netId <= 0 then return false end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    if GetEntityType(vehicle) ~= 2 then return false end

    local playerBucket = GetInventoryRoutingBucket(src)
    local okBucket, vehicleBucket = pcall(GetEntityRoutingBucket, vehicle)
    if not okBucket or playerBucket == nil or tonumber(vehicleBucket) ~= playerBucket then
        return false
    end

    local claimedPlate = TrimPlate(inventory:gsub('^' .. prefix .. '%-', ''))
    local actualPlate = nil
    local okPlate, plate = pcall(GetVehicleNumberPlateText, vehicle)
    if okPlate and type(plate) == 'string' and plate ~= '' then
        actualPlate = TrimPlate(plate)
        if claimedPlate ~= actualPlate then return false end
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    if prefix == 'glovebox' then
        local okIn, pedVehicle = pcall(GetVehiclePedIsIn, ped, false)
        if not okIn or pedVehicle ~= vehicle then return false end
    elseif #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) > (tonumber(Config.VehicleAccessDistance) or 5.0) then
        return false
    end

    return true, vehicle, prefix, actualPlate or claimedPlate
end

local function ResolveVehicleStorage(vehicle, prefix)
    local modelHash = GetEntityModel(vehicle)
    local limits = VEHICLE_MODEL_OVERRIDES[modelHash]

    if not limits then
        local sharedVehicle = QBCore.Shared.VehicleHashes and QBCore.Shared.VehicleHashes[modelHash]
        if not sharedVehicle and QBCore.Shared.Vehicles then
            for modelName, vehicleData in pairs(QBCore.Shared.Vehicles) do
                if vehicleData and (tonumber(vehicleData.hash) == modelHash or joaat(vehicleData.model or modelName) == modelHash) then
                    sharedVehicle = vehicleData
                    break
                end
            end
        end

        if sharedVehicle then
            local spawnName = type(sharedVehicle.model) == 'string' and sharedVehicle.model:lower() or nil
            limits = spawnName and VehicleStorage.byModel and VehicleStorage.byModel[spawnName] or nil
            if not limits then
                local category = type(sharedVehicle.category) == 'string' and sharedVehicle.category:lower() or nil
                local class = category and VEHICLE_CATEGORY_CLASS[category] or nil
                limits = class ~= nil and VehicleStorage[class] or nil
            end
        end
    end

    limits = limits or VehicleStorage.default
    if prefix == 'trunk' then
        return tonumber(limits.trunkSlots) or VehicleStorage.default.trunkSlots,
               tonumber(limits.trunkWeight) or VehicleStorage.default.trunkWeight
    end

    return tonumber(limits.gloveboxSlots) or VehicleStorage.default.gloveboxSlots,
           tonumber(limits.gloveboxWeight) or VehicleStorage.default.gloveboxWeight
end

RegisterCommand('inventory', function(source)
    if IsInventoryServerBusy(source) then return end
    local QBPlayer = QBCore.Functions.GetPlayer(source)
    if not QBPlayer then return end
    if not QBPlayer or QBPlayer.PlayerData.metadata['isdead'] or QBPlayer.PlayerData.metadata['inlaststand'] or QBPlayer.PlayerData.metadata['ishandcuffed'] then return end
    QBCore.Functions.TriggerClientCallback('qb-inventory:client:vehicleCheck', source, function(inventory, _, _, netId)
        if not inventory then return OpenInventory(source) end

        local verified, vehicle, prefix, plate = VerifyVehicleInventory(source, inventory, netId)
        if not verified then
            LogInventoryAccessDenied(source, inventory, 'vehicle-verify-failed')
            TriggerClientEvent('qb-inventory:client:closeInv', source)
            return
        end

        local slots, maxweight = ResolveVehicleStorage(vehicle, prefix)
        OpenInventory(source, inventory, {
            slots = slots,
            maxweight = maxweight,
            sessionKind = 'vehicle',
            sessionContext = {
                netId = tonumber(netId),
                prefix = prefix,
                plate = plate,
                bucket = GetInventoryRoutingBucket(source),
                accessDistance = Config.VehicleAccessDistance,
            }
        })
    end)
end, false)