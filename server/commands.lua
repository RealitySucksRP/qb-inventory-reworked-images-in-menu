---------------------------
-- server/commands.lua
---------------------------

QBCore.Commands.Add('giveitem', 'Give An Item (Admin Only)', { { name = 'id', help = 'Player ID' }, { name = 'item', help = 'Name of the item (not a label)' }, { name = 'amount', help = 'Amount of items' } }, false, function(source, args)
    local id = tonumber(args[1])
    local player = QBCore.Functions.GetPlayer(id)
    local itemName = tostring(args[2]):lower()
    local amount = tonumber(args[3]) or 1
    if itemName == 'cash' then
        QBCore.Functions.Notify(source, 'Spawning "cash" as an item is not allowed. Use /givemoney instead.', 'error', 7500)
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
    TriggerClientEvent('qb-inventory:client:ItemBox', id, itemData, 'add', amount)
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
    for k, v in pairs(QBCore.Shared.Items) do
        if QBCore.Shared.Items[k]['type'] ~= 'weapon' then
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
                TriggerClientEvent('qb-inventory:client:ItemBox', source, QBCore.Shared.Items[randitem.name], 'add')
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
    if Player(source).state.inv_busy then return end
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

-- The client used to hand back a bare 'trunk-<plate>' / 'glovebox-<plate>'
-- string and the server opened whatever it was given, so a spoofed callback
-- opened any vehicle on the map from anywhere. The client now also reports the
-- vehicle's network id, and the server resolves that entity itself and checks
-- it is a real vehicle, that the plate matches the name it was handed, and that
-- the player is actually at it.
--
-- Residual: `class` and `model` are still client-reported and only select slot
-- and weight limits from config/vehicles.lua. They cannot be used to reach a
-- different vehicle, only to overstate one's capacity.
local function VerifyVehicleInventory(src, inventory, netId)
    if type(inventory) ~= 'string' then return false end

    local prefix = inventory:match('^(trunk)%-') or inventory:match('^(glovebox)%-')
    if not prefix then return false end

    netId = tonumber(netId)
    if not netId then return false end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    if GetEntityType(vehicle) ~= 2 then return false end

    -- Plate check where the server build exposes it. Compared trimmed so the
    -- existing stash identifiers keep resolving unchanged.
    local okPlate, plate = pcall(GetVehicleNumberPlateText, vehicle)
    if okPlate and type(plate) == 'string' and plate ~= '' then
        local claimed = (inventory:gsub('^' .. prefix .. '%-', '')):gsub('%s+$', '')
        if claimed ~= (plate:gsub('%s+$', '')) then return false end
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    if prefix == 'glovebox' then
        -- A glovebox is only reachable from inside the vehicle.
        local okIn, pedVehicle = pcall(GetVehiclePedIsIn, ped)
        if okIn and pedVehicle and pedVehicle ~= 0 then
            return pedVehicle == vehicle
        end
    end

    return #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) <= 5.0
end

RegisterCommand('inventory', function(source)
    if Player(source).state.inv_busy then return end
    local QBPlayer = QBCore.Functions.GetPlayer(source)
    if not QBPlayer then return end
    if not QBPlayer or QBPlayer.PlayerData.metadata['isdead'] or QBPlayer.PlayerData.metadata['inlaststand'] or QBPlayer.PlayerData.metadata['ishandcuffed'] then return end
    QBCore.Functions.TriggerClientCallback('qb-inventory:client:vehicleCheck', source, function(inventory, class, model, netId)
        if not inventory then return OpenInventory(source) end

        if not VerifyVehicleInventory(source, inventory, netId) then
            LogInventoryAccessDenied(source, inventory, 'vehicle-verify-failed')
            return
        end

        if inventory:find('trunk-') then
            local slots = (VehicleStorage.byModel[model] and VehicleStorage.byModel[model].trunkSlots) or
                        (VehicleStorage[class] and VehicleStorage[class].trunkSlots) or
                        VehicleStorage.default.slots
            local maxweight = (VehicleStorage.byModel[model] and VehicleStorage.byModel[model].trunkWeight) or
                              (VehicleStorage[class] and VehicleStorage[class].trunkWeight) or
                              VehicleStorage.default.maxWeight

            OpenInventory(source, inventory, {
                slots = slots,
                maxweight = maxweight
            })
            return
        elseif inventory:find('glovebox-') then
            local slots = (VehicleStorage.byModel[model] and VehicleStorage.byModel[model].gloveboxSlots) or
                        (VehicleStorage[class] and VehicleStorage[class].gloveboxSlots) or
                        VehicleStorage.default.slots
            local maxweight = (VehicleStorage.byModel[model] and VehicleStorage.byModel[model].gloveboxWeight) or
                              (VehicleStorage[class] and VehicleStorage[class].gloveboxWeight) or
                              VehicleStorage.default.maxWeight
            OpenInventory(source, inventory, {
                slots = slots,
                maxweight = maxweight
            })
            return
        end
    end)
end, false)