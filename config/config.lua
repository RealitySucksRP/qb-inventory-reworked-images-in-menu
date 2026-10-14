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
    StashAccessDistance = 8.0,    -- generic stashes bind to their server-open position
    VehicleAccessDistance = 5.0, -- trunk session revalidated against the same net vehicle

    -- Server-side anti-spam/persistence tuning.
    UseItemRateLimitMs = 450,
    MoveRateLimitMs = 50, -- executor/spam backstop; normal NUI moves are request/response serialized
    -- Reserve a used non-weapon item's source slot while third-party progress/
    -- minigame logic finishes. A matching RemoveItem releases it immediately.
    UseItemReservationMs = 30000,
    SnapshotRateLimitMs = 100,
    DropListRateLimitMs = 1000,
    StashSaveDelayMs = 500,

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

    -- Optional strict server-authoritative vending coordinates. Base GTA map props
    -- are client-world objects and cannot always be proven by the server. When this
    -- list is populated and VendingStrictLocations is true, only these coordinates
    -- can open a vending shop. Leave false to preserve normal AddTargetModel vending;
    -- that fallback validates model/coords/net entity where possible but static map
    -- prop existence remains a client trust boundary.
    VendingStrictLocations = false,
    VendingLocations = {},
    VendingInteractionDistance = 3.0,

    VendingItems = {
        { name = 'kurkakola',    price = 4, amount = 50 },
        { name = 'water_bottle', price = 4, amount = 50 },
    }
}
