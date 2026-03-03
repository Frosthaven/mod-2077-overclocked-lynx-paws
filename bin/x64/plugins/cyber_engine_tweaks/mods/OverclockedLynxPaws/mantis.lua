local state = require("state")
local wallState = state.wallState

local Mantis = {}
Mantis.equipped = false -- cached equipped state

--- Check whether the player has mantis blades installed in the arms cyberware slot.
--- @return boolean True if mantis blades are installed.
function Mantis.checkInstalled()
    local ok, result = pcall(function()
        local esPlayerData = Game.GetScriptableSystemsContainer()
            :Get("EquipmentSystem"):GetPlayerData(wallState.player)
        local slotCount = esPlayerData:GetNumberOfSlots(gamedataEquipmentArea.ArmsCW, false)
        for i = 0, slotCount - 1 do
            local itemID = esPlayerData:GetItemInEquipSlot(gamedataEquipmentArea.ArmsCW, i)
            if itemID.id.hash and itemID.id.hash ~= 0 then
                local itemType = Game.GetTransactionSystem():GetItemData(wallState.player, itemID):GetItemType()
                if itemType.value == "Cyb_MantisBlades" then
                    return true
                end
            end
        end
        return false
    end)
    if ok then return result end
    return false
end

--- Check whether mantis blades are the active weapon (installed + no ranged/other melee weapon drawn).
--- @return boolean True if mantis blades would be used on melee attack.
function Mantis.checkEquipped()
    if not Mantis.checkInstalled() then return false end
    local ok, result = pcall(function()
        local ts = Game.GetTransactionSystem()
        local weapon = ts:GetItemInSlot(wallState.player, TweakDBID.new("AttachmentSlots.WeaponRight"))
        if weapon == nil then return true end
        local itemType = ts:GetItemData(wallState.player, weapon:GetItemID()):GetItemType()
        return itemType.value == "Cyb_MantisBlades"
    end)
    if ok then return result end
    return false
end

--- Bring out / unholster mantis blades (equip only, no attack animation).
--- Call at the very start of the mantis grab sequence so blades are visible immediately.
function Mantis.equip()
    local player = wallState.player or Game.GetPlayer()
    if not player then return end

    pcall(function()
        local eqs = Game.GetScriptableSystemsContainer():Get("EquipmentSystem")
        local request = EquipmentSystemWeaponManipulationRequest.new()
        request.owner = player
        request.requestType = Enum.new("EquipmentManipulationAction", "RequestLeftHandCyberware")
        eqs:QueueRequest(request)
    end)

    pcall(function()
        local itemHandling = AnimFeature_EquipUnequipItem.new()
        itemHandling.itemType = 2
        itemHandling.itemState = 2
        AnimationControllerComponent.ApplyFeature(player, CName.new("leftHandItemHandling"), itemHandling)

        local leftHandItem = AnimFeature_LeftHandItem.new()
        leftHandItem.itemInLeftHand = true
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandItem"), leftHandItem)

        local leftHandAnim = AnimFeature_LeftHandAnimation.new()
        leftHandAnim.lockLeftHandAnimation = true
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandAnimation"), leftHandAnim)

        local cwFeature = AnimFeature_LeftHandCyberware.new()
        cwFeature.state = 4  -- Equip state
        cwFeature.isQuickAction = false
        cwFeature.actionDuration = 0.5
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandCyberware"), cwFeature)
    end)
end

--- Trigger mantis blade wall-grab animation (arms extend outward).
--- Uses both EquipmentSystem request and direct AnimFeatures for reliability.
function Mantis.grab()
    local player = wallState.player or Game.GetPlayer()
    if not player then return end

    -- EquipmentSystem request (triggers full state machine)
    pcall(function()
        local eqs = Game.GetScriptableSystemsContainer():Get("EquipmentSystem")
        local request = EquipmentSystemWeaponManipulationRequest.new()
        request.owner = player
        request.requestType = Enum.new("EquipmentManipulationAction", "RequestLeftHandCyberware")
        eqs:QueueRequest(request)
    end)

    -- Direct AnimFeatures (reinforces the animation graph)
    pcall(function()
        local itemHandling = AnimFeature_EquipUnequipItem.new()
        itemHandling.itemType = 2
        itemHandling.itemState = 2
        AnimationControllerComponent.ApplyFeature(player, CName.new("leftHandItemHandling"), itemHandling)

        local leftHandItem = AnimFeature_LeftHandItem.new()
        leftHandItem.itemInLeftHand = true
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandItem"), leftHandItem)

        local leftHandAnim = AnimFeature_LeftHandAnimation.new()
        leftHandAnim.lockLeftHandAnimation = true
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandAnimation"), leftHandAnim)

        local cwFeature = AnimFeature_LeftHandCyberware.new()
        cwFeature.state = 8
        cwFeature.isQuickAction = true
        cwFeature.actionDuration = 0.5
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandCyberware"), cwFeature)
    end)
end

--- Release mantis blade wall-grab animation (arms retract).
--- Reverses all AnimFeatures and sends unequip request.
function Mantis.release()
    local player = wallState.player or Game.GetPlayer()
    if not player then return end

    -- EquipmentSystem unequip request
    pcall(function()
        local eqs = Game.GetScriptableSystemsContainer():Get("EquipmentSystem")
        local request = EquipmentSystemWeaponManipulationRequest.new()
        request.owner = player
        request.requestType = Enum.new("EquipmentManipulationAction", "UnequipLeftHandCyberware")
        eqs:QueueRequest(request)
    end)

    -- Reset direct AnimFeatures
    pcall(function()
        local itemHandling = AnimFeature_EquipUnequipItem.new()
        itemHandling.itemType = 0
        itemHandling.itemState = 0
        AnimationControllerComponent.ApplyFeature(player, CName.new("leftHandItemHandling"), itemHandling)

        local leftHandItem = AnimFeature_LeftHandItem.new()
        leftHandItem.itemInLeftHand = false
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandItem"), leftHandItem)

        local leftHandAnim = AnimFeature_LeftHandAnimation.new()
        leftHandAnim.lockLeftHandAnimation = false
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandAnimation"), leftHandAnim)

        local cwFeature = AnimFeature_LeftHandCyberware.new()
        cwFeature.state = 0
        cwFeature.isQuickAction = false
        cwFeature.actionDuration = 0.0
        AnimationControllerComponent.ApplyFeature(player, CName.new("LeftHandCyberware"), cwFeature)
    end)
end

return Mantis
