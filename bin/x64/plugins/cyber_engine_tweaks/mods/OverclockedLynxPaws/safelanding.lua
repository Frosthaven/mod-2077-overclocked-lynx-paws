local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local Helpers = require("helpers")
local input = require("input")

local SafeLanding = {}

--- Update the crouch buffer timer and expire the buffer if it exceeds the safe land window.
--- @param dt number Delta time in seconds.
function SafeLanding.updateCrouchBuffer(dt)
    if wallState.crouchBuffered then
        wallState.crouchBufferTimer = wallState.crouchBufferTimer + dt
        if wallState.crouchBufferTimer > cfg.safeLandWindow then
            wallState.crouchBuffered = false
        end
    end
end

--- Set or clear the Redscript quest fact that blocks hard/death landing states.
function SafeLanding.updateSafeLandFact()
    local qs = Game.GetQuestsSystem()
    if qs then
        local want = (wallState.crouchBuffered and wallState.phase == "IDLE") and 1 or 0
        qs:SetFact(CName.new("wr_safe_land"), want)
    end
end

--- Initiate the safe landing roll sequence: cancel hard landing, force crouch, holster weapon, and begin forward roll.
function SafeLanding.triggerSafeRoll(fallDist)
    local bb = Helpers.getPlayerBlackboard()
    if bb then
        bb:SetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.Fall, 0, true)
        bb:SetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.Landing, 0, true)
    end
    -- Cancel hard landing animation
    local feat = NewObject("AnimFeature_Landing")
    feat.impactSpeed = 0.0
    feat.type = 0
    AnimationControllerComponent.ApplyFeatureToReplicate(
        wallState.player, CName.new("Landing"), feat)
    -- Force crouch during pre-roll delay + roll
    StatusEffectHelper.ApplyStatusEffect(wallState.player,
        TweakDBID.new("GameplayRestriction.ForceCrouch"))
    -- Holster weapon only (not cyberarms, preserves Equipment EX arms)
    local ts = Game.GetTransactionSystem()
    local hadWeapon = ts and (
        ts:GetItemInSlot(wallState.player, TweakDBID.new("AttachmentSlots.WeaponRight")) ~= nil or
        ts:GetItemInSlot(wallState.player, TweakDBID.new("AttachmentSlots.WeaponLeft")) ~= nil)
    wallState.safeRollShouldReequip = hadWeapon or false
    local holsterReq = NewObject("EquipmentSystemWeaponManipulationRequest")
    holsterReq.requestType = EquipmentManipulationAction.UnequipWeapon
    holsterReq.owner = wallState.player
    Game.GetScriptableSystemsContainer():Get(CName.new("EquipmentSystem")):QueueRequest(holsterReq)
    -- Start roll immediately (no pre-roll delay)
    local fwd = Game.GetCameraSystem():GetActiveCameraForward()
    wallState.safeRollDir = Vector4.Normalize(Vector4.new(fwd.x, fwd.y, 0, 0))
    wallState.safeRollTimer = 0
    wallState.safeRollYaw = wallState.player:GetWorldYaw()
    wallState.safeRollSoundCountdown = 0.58
    Helpers.playSound("q304_sc_09b_songbird_stumbles_tunnel")
    wallState.safeRollMeshIsHidden = false
    local qs = Game.GetQuestsSystem()
    if qs then
        qs:SetFact(CName.new("wr_safe_land"), 0)
        qs:SetFact(CName.new("wr_safe_roll"), 1)
    end
    wallState.crouchBuffered = false
    wallState.crouchBufferTimer = 0
    -- Scale roll speed with fall height, but never slower than current horizontal speed
    local fd = math.max(fallDist or 3.0, 3.0)
    local fallSpeed = math.min(33.0, 2.5 + (fd - 3.0) * 0.125)
    local currentSpeed = Vector4.Length2D(wallState.player:GetVelocity()) * 0.5
    wallState.safeRollSpeed = math.max(fallSpeed, currentSpeed)
end

--- Clear the crouch buffer without triggering a roll (used for short falls).
function SafeLanding.clearBuffer()
    wallState.crouchBuffered = false
    wallState.crouchBufferTimer = 0
end

--- Clear all mod-owned quest facts. Called on mod load, mod shutdown, master
--- toggle off, and airborne→ground transition so the Redscript hooks can
--- never read a stale fact when Lua isn't actively managing it.
function SafeLanding.clearAllFacts()
    local qs = Game.GetQuestsSystem()
    if not qs then return end
    qs:SetFact(CName.new("wr_safe_land"), 0)
    qs:SetFact(CName.new("wr_landing_safe"), 0)
    qs:SetFact(CName.new("wr_safe_roll"), 0)
    qs:SetFact(CName.new("wr_uncrouch"), 0)
    qs:SetFact(CName.new("wr_sprint"), 0)
    qs:SetFact(CName.new("wr_wall_active"), 0)
    qs:SetFact(CName.new("wr_reset_jumps"), 0)
end

--- Clear safe-landing communication facts only. Used on every airborne→ground
--- transition so a leaked wr_landing_safe (set by the Redscript hook when the
--- buffer was alive but Lua's roll trigger gate later failed) can't carry
--- across falls.
function SafeLanding.clearLandingFacts()
    local qs = Game.GetQuestsSystem()
    if not qs then return end
    qs:SetFact(CName.new("wr_safe_land"), 0)
    qs:SetFact(CName.new("wr_landing_safe"), 0)
end

--- Tick down the roll sound countdown timer and stop the sound when it expires.
--- @param dt number Delta time in seconds.
function SafeLanding.updateRollSound(dt)
    if wallState.safeRollSoundCountdown then
        wallState.safeRollSoundCountdown = wallState.safeRollSoundCountdown - dt
        if wallState.safeRollSoundCountdown <= 0 then
            Helpers.stopSound("q304_sc_09b_songbird_stumbles_tunnel")
            wallState.safeRollSoundCountdown = nil
        end
    end
end

--- Show character + weapon meshes and queue a re-equip request. Idempotent
--- via the safeRollMeshIsHidden / safeRollShouldReequip flags so callers
--- (mid-roll restore at 70% OR standup restore on spin-disabled rolls) can
--- both hit it safely.
function SafeLanding.restoreModelAndWeapon()
    if wallState.safeRollMeshIsHidden then
        Helpers.showCharacterModel()
        Helpers.showWeaponModel()
        wallState.safeRollMeshIsHidden = false
    end
    if wallState.safeRollShouldReequip then
        local equipReq = NewObject("EquipmentSystemWeaponManipulationRequest")
        equipReq.requestType = EquipmentManipulationAction.ReequipWeapon
        equipReq.owner = wallState.player
        Game.GetScriptableSystemsContainer():Get(CName.new("EquipmentSystem")):QueueRequest(equipReq)
        wallState.safeRollShouldReequip = false
    end
end

--- Update the safe roll animation each frame: teleport forward with collision and apply camera pitch spin.
--- @param dt number Delta time in seconds.
--- @return boolean True if a roll is actively in progress.
function SafeLanding.updateRoll(dt)
    if not wallState.safeRollTimer then return false end

    wallState.safeRollTimer = wallState.safeRollTimer + dt
    local t = wallState.safeRollTimer / wallState.safeRollDuration

    if t < 1.0 then
        -- Hide player mesh: at 15% normally, or immediately when camera spin
        -- is disabled (otherwise the crouched body would be visible right
        -- under the lowered camera).
        local hideThreshold = cfg.safeLandDisableCameraSpin and 0 or 0.15
        if not wallState.safeRollMeshIsHidden and t >= hideThreshold then
            Helpers.hideCharacterModel()
            wallState.safeRollMeshIsHidden = true
        end
        -- Restore player mesh at 70% — but if camera spin is disabled, hold
        -- the model hidden until the player stands up (handled in updateUncrouch),
        -- so the absent crouched body doesn't pop into view mid-slide.
        if wallState.safeRollMeshIsHidden and t >= 0.7 and not cfg.safeLandDisableCameraSpin then
            SafeLanding.restoreModelAndWeapon()
        end
        -- Per-frame forward impulse (dt-scaled for framerate independence)
        local d = wallState.safeRollDir
        if d then
            local spd = wallState.safeRollSpeed * dt * 10.0
            local imp = PSMImpulse.new()
            imp.id = "impulse"
            imp.impulse = Vector4.new(d.x * spd, d.y * spd, 0, 0)
            wallState.player:QueueEvent(imp)
        end
        local camComp = wallState.player:GetFPPCameraComponent()
        if camComp then
            -- Camera drop: fast 0.1s lerp down to -1.4m, hold, fast 0.1s lerp
            -- back up at the end. Reads as a quick physical drop into the roll.
            local elapsed = wallState.safeRollTimer
            local lerpDur = 0.1
            local dropDepth = -0.7
            local zOffset = dropDepth
            if elapsed < lerpDur then
                zOffset = dropDepth * (elapsed / lerpDur)
            elseif elapsed > wallState.safeRollDuration - lerpDur then
                local backT = (wallState.safeRollDuration - elapsed) / lerpDur
                zOffset = dropDepth * math.max(0, backT)
            end
            camComp:SetLocalPosition(Vector4.new(0, 0, zOffset, 0))
            if not cfg.safeLandDisableCameraSpin then
                -- Camera pitch: 0.1s delay then full 360° forward roll, smoothstep eased.
                local delay = 0.1
                local pitch = 0
                if elapsed > delay then
                    local spinT = (elapsed - delay) / (wallState.safeRollDuration - delay)
                    pitch = -Helpers.smoothstep(spinT) * 360.0
                end
                camComp:SetLocalOrientation(EulerAngles.ToQuat(EulerAngles.new(0, pitch, 0)))
            end
        end
    else
        -- Roll complete — store speed for exit impulse at uncrouch
        wallState.safeRollExitSpeed = math.min(20.0, wallState.safeRollSpeed * 0.5)
        wallState.safeRollTimer = nil
        -- Start uncrouch → sprint sequence (no delay — immediate)
        wallState.safeRollUncrouch = 0.01
        -- Reset camera position and orientation
        local camComp = wallState.player:GetFPPCameraComponent()
        if camComp then
            camComp:SetLocalPosition(Vector4.new(0, 0, 0, 0))
            camComp:SetLocalOrientation(EulerAngles.ToQuat(EulerAngles.new(0, 0, 0)))
        end
    end
    return true
end

--- Update the uncrouch and sprint-resume sequence after the safe roll completes.
--- @param dt number Delta time in seconds.
function SafeLanding.updateUncrouch(dt)
    if wallState.safeRollUncrouch then
        -- Keep pushing forward during uncrouch
        local d = wallState.safeRollDir
        if d and wallState.safeRollExitSpeed then
            local spd = wallState.safeRollExitSpeed * dt
            local imp = PSMImpulse.new()
            imp.id = "impulse"
            imp.impulse = Vector4.new(d.x * spd, d.y * spd, 0, 0)
            wallState.player:QueueEvent(imp)
        end

        wallState.safeRollUncrouch = wallState.safeRollUncrouch - dt
        if wallState.safeRollUncrouch <= 0 then
            -- If the model was held hidden through the whole roll (spin
            -- disabled path), restore it now at standup.
            SafeLanding.restoreModelAndWeapon()
            -- Remove ForceCrouch status effect
            StatusEffectHelper.RemoveStatusEffect(wallState.player,
                TweakDBID.new("GameplayRestriction.ForceCrouch"))
            -- Clear CrouchToggled via Redscript hook
            local qs = Game.GetQuestsSystem()
            if qs then qs:SetFact(CName.new("wr_uncrouch"), 1) end
            wallState.safeRollUncrouch = nil
            Helpers.playSound("ono_v_effort_short")
            -- Fire exit impulse
            if d and wallState.safeRollExitSpeed then
                local spd = wallState.safeRollExitSpeed
                local imp = PSMImpulse.new()
                imp.id = "impulse"
                imp.impulse = Vector4.new(d.x * spd, d.y * spd, 0, 0)
                wallState.player:QueueEvent(imp)
            end
            -- Force sprint if holding sprint
            if input.pressingSprint then
                local qs2 = Game.GetQuestsSystem()
                if qs2 then qs2:SetFact(CName.new("wr_sprint"), 1) end
            end
            wallState.safeRollExitSpeed = nil
            wallState.safeRollDir = nil
        end
    end
end

--- Clear stale safe roll and uncrouch quest facts after a grace period once all roll state is finished.
--- @param dt number Delta time in seconds.
function SafeLanding.updateCleanup(dt)
    if not wallState.safeRollTimer and not wallState.safeRollUncrouch then
        if not wallState.safeRollCleanupTimer then
            wallState.safeRollCleanupTimer = 0.2  -- give Redscript time to process facts
        else
            wallState.safeRollCleanupTimer = wallState.safeRollCleanupTimer - dt
            if wallState.safeRollCleanupTimer <= 0 then
                wallState.safeRollCleanupTimer = nil
                local qs = Game.GetQuestsSystem()
                if qs then
                    if qs:GetFact(CName.new("wr_safe_roll")) > 0 then
                        qs:SetFact(CName.new("wr_safe_roll"), 0)
                    end
                    if qs:GetFact(CName.new("wr_uncrouch")) > 0 then
                        qs:SetFact(CName.new("wr_uncrouch"), 0)
                    end
                end
            end
        end
    else
        wallState.safeRollCleanupTimer = nil
    end
end

return SafeLanding
