local QBCore = exports['qb-core']:GetCoreObject()

local itemCounts = nil
local function rebuildCounts(pd)
    itemCounts = {}
    if not pd or not pd.items then return end
    for _, it in pairs(pd.items) do
        if it and it.name then
            itemCounts[it.name] = (itemCounts[it.name] or 0) + (it.amount or it.count or 0)
        end
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() rebuildCounts(QBCore.Functions.GetPlayerData()) end)
RegisterNetEvent('QBCore:Player:SetPlayerData',  function(pd) rebuildCounts(pd) end)

local function ensureCountsSync(timeoutMs)
    if itemCounts ~= nil then return true end
    local done = false
    QBCore.Functions.TriggerCallback('qb-inventory:server:GetItemCounts', function(map)
        itemCounts = map or {}
        done = true
    end)
    local t = GetGameTimer()
    while not done do
        Wait(0)
        if GetGameTimer() - t > (timeoutMs or 1500) then
            print('^3[qb-inventory] GetItemCounts timeout^7')
            return false
        end
    end
    return true
end

local function localHas(items, amount)
    if not ensureCountsSync(1500) then return false end
    if type(items) == 'string' then
        return (itemCounts[items] or 0) >= (amount or 1)
    elseif type(items) == 'table' then
        for _, name in pairs(items) do
            if (itemCounts[name] or 0) < 1 then return false end
        end
        return true
    end
    return false
end

exports('HasItem', function(items, amount)
    return localHas(items, amount)
end)

CreateThread(function()
    rebuildCounts(QBCore.Functions.GetPlayerData())
    print('^2[qb-inventory] HasItem client export active.^7')
end)