Config = {
    -- RS Punk keeps its existing cash-as-item behavior enabled.
    -- Requires the qb-core cash patch and a `cash` item in qb-core/shared/items.lua.
    CashAsItem = true,

    -- Canonical physical currency item used by cash sync, death/respawn
    -- preservation, SetInventory protection, and direct RemoveItem guards.
    -- Keep this aligned with qb-core/shared/items.lua.
    CashItemName = 'cash',

    -- Recommended server.cfg safety defaults for Cash-As-Item servers:
    -- set qb_protect_cash_while_dead 1
    -- set qb_death_cash_trace 1

    -- Preserve the existing RS Punk HUD integration.
    CustomHUD = {
        Enabled = true,
        ResourceName = 'rs-lilhudlife',
        ExportName = 'SetHUDLifeVisible'
    },

    -- Discord webhook for player robbery logs. Leave empty to disable logging.
    RobberyWebhook = '',

    -- Image a /giveitem printerdocument starts with. Leave empty for none.
    DefaultPrinterDocumentUrl = '',

    MaxWeight = 120000,
    MaxSlots = 40,

    -- Non-unique items may stack by name even when freshness differs. The merged
    -- stack keeps the earlier expiry, so stacking can never extend item life.
    StackWithDifferentExpiry = true,

    StashSize = {
        maxweight = 2000000,
        slots = 100
    },

    DropSize = {
        maxweight = 1000000,
        slots = 50
    },

    -- Revalidated server-side on every move while a secondary inventory is open.
    DropAccessDistance = 3.5,
    PlayerAccessDistance = 3.5,
    ShopAccessDistance = 6.0,

    Keybinds = {
        Open = 'TAB',
        Hotbar = 'Z'
    },

    CleanupDropTime = 15,
    CleanupDropInterval = 1,

    ItemDropObject = `bkr_prop_duffel_bag_01a`,
    ItemDropObjectBone = 28422,
    ItemDropObjectOffset = {
        vector3(0.260000, 0.040000, 0.000000),
        vector3(90.000000, 0.000000, -78.989998),
    },

    VendingObjects = {
        'prop_vend_soda_01',
        'prop_vend_soda_02',
        'prop_vend_water_01',
        'prop_vend_coffe_01',
    },

    VendingItems = {
        { name = 'kurkakola',    price = 4, amount = 50 },
        { name = 'water_bottle', price = 4, amount = 50 },
    }
}
