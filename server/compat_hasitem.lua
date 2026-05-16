local QBCore = exports['qb-core']:GetCoreObject()

local function countItem(Player, name)
    local it = Player.Functions.GetItemByName(name)
    return (it and it.amount) or 0
end

QBCore.Functions.CreateCallback('qb-inventory:server:GetItemCounts', function(src, cb)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then cb({}) return end
    local map = {}
    local pd = Player.PlayerData
    if pd and pd.items then
        for _, it in pairs(pd.items) do
            if it and it.name then
                map[it.name] = (map[it.name] or 0) + (it.amount or 0)
            end
        end
    end
    cb(map)
end)

QBCore.Functions.CreateCallback('qb-inventory:server:HasItem', function(src, cb, items, amount)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then cb(false) return end
    if type(items) == 'string' then
        cb(countItem(Player, items) >= (amount or 1)); return
    elseif type(items) == 'table' then
        for _, name in pairs(items) do
            if countItem(Player, name) < 1 then cb(false) return end
        end
        cb(true); return
    end
    cb(false)
end)

AddEventHandler('onResourceStart', function(res)
    if res == GetCurrentResourceName() then
        print('^2[qb-inventory] Server callbacks ready.^7')
    end
end)