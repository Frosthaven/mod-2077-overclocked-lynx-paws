local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local Helpers = require("helpers")

local Kerenzikov = {}

Kerenzikov.speedMultiplier = 0.3  -- time dilation multiplier during wall actions (vert speed, timer)
Kerenzikov.wallRunSpeed    = 0.35 -- fixed lateral wall run speed during Kerenzikov (m/s)

-- Cached Kerenzikov stats (refreshed alongside settings sync)
Kerenzikov.worldScale = 0.2
Kerenzikov.playerScale = 1.0

--- Get the Kerenzikov world time dilation scale from player stats.
--- @return number The world time scale (0-1), defaults to 0.2 if unavailable.
function Kerenzikov.getDilation()
    local stats = Game.GetStatsSystem()
    if not stats then return 0.2 end
    local entityID = wallState.player:GetEntityID()
    local ok, worldScale = pcall(function()
        return stats:GetStatValue(entityID, gamedataStatType.TimeDilationKerenzikovTimeScale)
    end)
    if ok and worldScale and worldScale > 0 and worldScale < 1.0 then
        return worldScale
    end
    return 0.2
end

--- Get the Kerenzikov player-local time dilation scale from player stats.
--- @return number The player time scale (0-1), defaults to 1.0 if unavailable.
function Kerenzikov.getPlayerScale()
    local stats = Game.GetStatsSystem()
    if not stats then return 1.0 end
    local entityID = wallState.player:GetEntityID()
    local ok, val = pcall(function()
        return stats:GetStatValue(entityID, gamedataStatType.TimeDilationKerenzikovPlayerTimeScale)
    end)
    if ok and val and val > 0 and val < 1.0 then
        return val
    end
    return 1.0
end

--- Check whether the player has the Kerenzikov cyberware equipped.
--- @return boolean True if the player's HasKerenzikov stat is greater than zero.
function Kerenzikov.hasKerenzikov()
    local stats = Game.GetStatsSystem()
    return stats and stats:GetStatValue(wallState.player:GetEntityID(), gamedataStatType.HasKerenzikov) > 0
end

--- Check whether the player has unlocked the Air Kerenzikov perk (Reflexes_Inbetween_Left_3).
--- @return boolean True if the perk is bought at any level.
function Kerenzikov.hasAirKerenzikovPerk()
    local pds = Game.GetScriptableSystemsContainer():Get("PlayerDevelopmentSystem")
    if not pds then return false end
    local data = pds:GetDevelopmentData(wallState.player)
    if not data then return false end
    return data:IsNewPerkBoughtAnyLevel(gamedataNewPerkType.Reflexes_Inbetween_Left_3)
end

--- Check whether the player is currently aiming down sights via the upper body state machine.
--- @return boolean True if the UpperBody blackboard state equals 6 (ADS).
function Kerenzikov.isAimingDownSights()
    local bb = Helpers.getPlayerBlackboard()
    if not bb then return false end
    return bb:GetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.UpperBody) == 6
end

--- Activate Kerenzikov time dilation and apply the player buff status effect.
function Kerenzikov.activate()
    if not wallState.kerenzikovActive then
        local ts = Game.GetTimeSystem()
        ts:SetTimeDilation(CName.new("kereznikov"), Kerenzikov.worldScale, 999.0,
            CName.new("KereznikovDodgeEaseIn"), CName.new("KerenzikovEaseOut"))
        if Kerenzikov.playerScale < 1.0 then
            local ok = pcall(function()
                ts:SetTimeDilationOnLocalPlayerZero(Kerenzikov.playerScale)
            end)
            if not ok then
                ts:SetIgnoreTimeDilationOnLocalPlayerZero(true)
            end
        else
            ts:SetIgnoreTimeDilationOnLocalPlayerZero(true)
        end
        StatusEffectHelper.ApplyStatusEffect(wallState.player,
            TweakDBID.new("BaseStatusEffect.KerenzikovPlayerBuff"))
        wallState.kerenzikovActive = true
    end
end

--- Pause Kerenzikov time dilation without removing the active state or status effect.
function Kerenzikov.pause()
    if wallState.kerenzikovActive then
        local ts = Game.GetTimeSystem()
        ts:UnsetTimeDilation(CName.new("kereznikov"), CName.new("KerenzikovEaseOut"))
        ts:UnsetTimeDilationOnLocalPlayerZero(CName.new("kereznikov"))
        ts:SetIgnoreTimeDilationOnLocalPlayerZero(false)
    end
end

--- Fully deactivate Kerenzikov by removing time dilation and the player buff status effect.
function Kerenzikov.deactivate()
    if wallState.kerenzikovActive then
        local ts = Game.GetTimeSystem()
        ts:UnsetTimeDilation(CName.new("kereznikov"), CName.new("KerenzikovEaseOut"))
        ts:UnsetTimeDilationOnLocalPlayerZero(CName.new("kereznikov"))
        ts:SetIgnoreTimeDilationOnLocalPlayerZero(false)
        StatusEffectHelper.RemoveStatusEffect(wallState.player,
            TweakDBID.new("BaseStatusEffect.KerenzikovPlayerBuff"))
        wallState.kerenzikovActive = false
    end
end

--- Update Kerenzikov state based on aim-down-sights status during wall actions.
function Kerenzikov.updateADS()
    if not cfg.triggerKerenzikov or not Kerenzikov.hasKerenzikov() then return end
    if wallState.kerenzikovActive and not Game.GetStatusEffectSystem():HasStatusEffect(
        wallState.player:GetEntityID(), TweakDBID.new("BaseStatusEffect.KerenzikovPlayerBuff")) then
        Kerenzikov.deactivate()
    elseif Kerenzikov.isAimingDownSights() then
        if wallState.kerenzikovActive then
            local ts = Game.GetTimeSystem()
            ts:SetTimeDilation(CName.new("kereznikov"), Kerenzikov.worldScale, 999.0,
                CName.new("KereznikovDodgeEaseIn"), CName.new("KerenzikovEaseOut"))
            ts:SetIgnoreTimeDilationOnLocalPlayerZero(true)
        else
            Kerenzikov.activate()
        end
    else
        Kerenzikov.deactivate()
    end
end

--- Award Shinobi (Reflexes) skill XP to the player from locomotion actions.
--- @param amount number The amount of XP to award (must be positive).
function Kerenzikov.awardShinobiXP(amount)
    if not cfg.gainShinobiSkill or amount <= 0 then return end
    pcall(function()
        RPGManager.AwardExperienceFromLocomotion(wallState.player, amount)
    end)
end

return Kerenzikov
