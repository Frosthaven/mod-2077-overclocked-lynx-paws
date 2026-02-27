local state = require("state")
local wallState = state.wallState

local LynxPaw = {}

---------------------------------------------------------------------------
-- Lynx Paw cyberware state
---------------------------------------------------------------------------
LynxPaw.hashes = nil   -- hash lookup table, populated in init()
LynxPaw.equipped = false -- cached equipped state, refreshed every 2s

local lynxPawVariants = {
    "Items.AdvancedCatPawsUncommon",
    "Items.AdvancedCatPawsUncommonPlus",
    "Items.AdvancedCatPawsRare",
    "Items.AdvancedCatPawsRarePlus",
    "Items.AdvancedCatPawsEpic",
    "Items.AdvancedCatPawsEpicPlus",
    "Items.AdvancedCatPawsLegendary",
    "Items.AdvancedCatPawsLegendaryPlus",
    "Items.AdvancedCatPawsLegendaryPlusPlus",
}

--- Build a hash lookup table from all Lynx Paw cyberware variant TweakDB IDs.
function LynxPaw.initHashes()
    if LynxPaw.hashes then return end
    LynxPaw.hashes = {}
    for _, path in ipairs(lynxPawVariants) do
        LynxPaw.hashes[ItemID.new(TweakDBID.new(path)).id.hash] = true
    end
end

--- Check whether the player currently has any Lynx Paw variant equipped in the legs cyberware slot.
--- @return boolean True if a Lynx Paw variant is equipped.
function LynxPaw.checkEquipped()
    local ok, result = pcall(function()
        local esPlayerData = Game.GetScriptableSystemsContainer()
            :Get("EquipmentSystem"):GetPlayerData(wallState.player)
        local slotCount = esPlayerData:GetNumberOfSlots(gamedataEquipmentArea.LegsCW, false)
        for i = 0, slotCount - 1 do
            local hash = esPlayerData:GetItemInEquipSlot(gamedataEquipmentArea.LegsCW, i).id.hash
            if hash and hash ~= 0 and LynxPaw.hashes and LynxPaw.hashes[hash] then
                return true
            end
        end
        return false
    end)
    if ok then return result end
    return false
end

---------------------------------------------------------------------------
-- TweakDB helpers (for Lynx Paw stat/description overrides)
---------------------------------------------------------------------------
local function createRecordIfNotExists(name, rtype)
    if TweakDB:GetRecord(name) == nil then
        TweakDB:CreateRecord(name, rtype)
    end
end

local function createConstantStatModifier(name, modType, statType, value)
    createRecordIfNotExists(name, "gamedataConstantStatModifier_Record")
    TweakDB:SetFlat(name .. ".modifierType", modType)
    TweakDB:SetFlat(name .. ".statType", statType)
    TweakDB:SetFlat(name .. ".value", value)
end

local function insertRecordIntoList(tab, path)
    local recordID = TweakDB:GetRecord(path):GetID()
    for _, val in pairs(tab) do
        if recordID == val then return end
    end
    table.insert(tab, path)
end

---------------------------------------------------------------------------
-- Lynx Paw TweakDB overrides (stats + descriptions)
---------------------------------------------------------------------------
local lynxPawTierStats = {
    ["Items.AdvancedCatPawsUncommon"]          = { crouch = 0.08, fallDmg = 0.20 },
    ["Items.AdvancedCatPawsUncommonPlus"]       = { crouch = 0.11, fallDmg = 0.21 },
    ["Items.AdvancedCatPawsRare"]              = { crouch = 0.14, fallDmg = 0.22 },
    ["Items.AdvancedCatPawsRarePlus"]           = { crouch = 0.16, fallDmg = 0.24 },
    ["Items.AdvancedCatPawsEpic"]              = { crouch = 0.19, fallDmg = 0.25 },
    ["Items.AdvancedCatPawsEpicPlus"]           = { crouch = 0.22, fallDmg = 0.26 },
    ["Items.AdvancedCatPawsLegendary"]         = { crouch = 0.25, fallDmg = 0.28 },
    ["Items.AdvancedCatPawsLegendaryPlus"]      = { crouch = 0.27, fallDmg = 0.29 },
    ["Items.AdvancedCatPawsLegendaryPlusPlus"]  = { crouch = 0.30, fallDmg = 0.30 },
}

-- Stamina reduction per Lynx Paw tier (0-80%)
local lynxPawStaminaReduction = {
    ["Items.AdvancedCatPawsUncommon"]          = 0.00,
    ["Items.AdvancedCatPawsUncommonPlus"]       = 0.10,
    ["Items.AdvancedCatPawsRare"]              = 0.20,
    ["Items.AdvancedCatPawsRarePlus"]           = 0.30,
    ["Items.AdvancedCatPawsEpic"]              = 0.40,
    ["Items.AdvancedCatPawsEpicPlus"]           = 0.50,
    ["Items.AdvancedCatPawsLegendary"]         = 0.60,
    ["Items.AdvancedCatPawsLegendaryPlus"]      = 0.70,
    ["Items.AdvancedCatPawsLegendaryPlusPlus"]  = 0.80,
}

--- Get the stamina cost multiplier based on the equipped Lynx Paw tier.
--- @return number Multiplier between 0.2 and 1.0 (lower = less drain). Returns 1.0 if no Lynx Paw equipped.
function LynxPaw.getStaminaMultiplier()
    local ok, result = pcall(function()
        local esPlayerData = Game.GetScriptableSystemsContainer()
            :Get("EquipmentSystem"):GetPlayerData(wallState.player)
        local slotCount = esPlayerData:GetNumberOfSlots(gamedataEquipmentArea.LegsCW, false)
        for i = 0, slotCount - 1 do
            local itemID = esPlayerData:GetItemInEquipSlot(gamedataEquipmentArea.LegsCW, i)
            local hash = itemID.id.hash
            if hash and hash ~= 0 and LynxPaw.hashes and LynxPaw.hashes[hash] then
                for variant, reduction in pairs(lynxPawStaminaReduction) do
                    local variantHash = ItemID.new(TweakDBID.new(variant)).id.hash
                    if variantHash == hash then
                        return 1.0 - reduction
                    end
                end
            end
        end
        return 1.0
    end)
    return ok and result or 1.0
end

--- Create TweakDB stat modifiers and effectors for all Lynx Paw variants (fall damage, crouch speed, silent landing).
function LynxPaw.setupStats()
    -- Shared stat modifier records (created once)
    createConstantStatModifier("Items.CatPawsCanLandSilently", "Additive", "BaseStats.CanLandSilently", 1)

    -- Crouch speed prereq (IsPlayerCrouching)
    createRecordIfNotExists("Items.CatPawsStealthMovementMultiPrereqRecord", "gamedataMultiPrereq_Record")
    TweakDB:SetFlat("Items.CatPawsStealthMovementMultiPrereqRecord.aggregationType", "AND")
    TweakDB:SetFlat("Items.CatPawsStealthMovementMultiPrereqRecord.prereqClassName", "gameMultiPrereq")
    TweakDB:SetFlat("Items.CatPawsStealthMovementMultiPrereqRecord.nestedPrereqs", {"Perks.IsPlayerCrouching"})

    for _, variant in ipairs(lynxPawVariants) do
        local tierStats = lynxPawTierStats[variant] or { crouch = 0.15, fallDmg = 0.25 }
        local variantKey = variant:match("%.(.+)$")

        -- Sound radius: 0.5x (50% reduction, matches vanilla)
        TweakDB:SetFlat(variant .. "_inline1.value", 0.5)

        -- Per-tier fall damage reduction (20-30%)
        local fallDmgName = "Items.CatPawsFallDamage_" .. variantKey
        createConstantStatModifier(fallDmgName, "Additive", "BaseStats.FallDamageReduction", tierStats.fallDmg)

        -- Insert fall damage + silent landing into stats list
        local stats = TweakDB:GetFlat(variant .. "_inline0.stats")
        if stats then
            insertRecordIntoList(stats, fallDmgName)
            insertRecordIntoList(stats, "Items.CatPawsCanLandSilently")
            TweakDB:SetFlat(variant .. "_inline0.stats", stats)
        end

        -- Crouch speed effector (scaled per tier)
        local crouchSpeed = tierStats.crouch
        local effectorName = "Items.CatPawsCrouchSpeed_" .. variantKey
        local modGroupName = effectorName .. "_StatGroup"
        local modifierName = effectorName .. "_Modifier"

        createConstantStatModifier(modifierName, "AdditiveMultiplier", "BaseStats.MaxSpeed", crouchSpeed)

        createRecordIfNotExists(modGroupName, "gamedataStatModifierGroup_Record")
        TweakDB:SetFlat(modGroupName .. ".statModsLimit", -1)
        TweakDB:SetFlat(modGroupName .. ".statModifiers", {modifierName})

        createRecordIfNotExists(effectorName, "gamedataApplyStatGroupEffector_Record")
        TweakDB:SetFlat(effectorName .. ".effectorClassName", "ApplyStatGroupEffector")
        TweakDB:SetFlat(effectorName .. ".prereqRecord", "Items.CatPawsStealthMovementMultiPrereqRecord")
        TweakDB:SetFlat(effectorName .. ".statGroup", modGroupName)

        local effectors = TweakDB:GetFlat(variant .. "_inline0.effectors")
        if effectors then
            insertRecordIntoList(effectors, effectorName)
            TweakDB:SetFlat(variant .. "_inline0.effectors", effectors)
        end
    end
end

local function toLocKeyString(key)
    if type(key) == "string" then
        return "LocKey#" .. tostring(LocKey(key).hash):gsub("ULL$", "")
    end
    return ""
end

--- Update the localized descriptions for all Lynx Paw cyberware variants with tier-specific stat values.
function LynxPaw.updateDescriptions()
    local descKey = toLocKeyString("WallRunning-LynxPaws-Description")
    if descKey == "" then return end

    local soundReduction = 50

    for _, variant in ipairs(lynxPawVariants) do
        pcall(function()
            local tierStats = lynxPawTierStats[variant] or { crouch = 0.15, fallDmg = 0.25 }
            local crouchPct = math.floor(tierStats.crouch * 100)
            local fallPct   = math.floor(tierStats.fallDmg * 100)
            TweakDB:SetFlat(variant .. "_inline5.localizedDescription", descKey)
            TweakDB:SetFlat(variant .. "_inline5.intValues", {
                soundReduction,
                fallPct,
                crouchPct,
            })
        end)
    end
end

return LynxPaw
