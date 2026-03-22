local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local Helpers = require("helpers")

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
    local fallSpeed = math.min(25.0, 2.66 + (fd - 3.0) * 0.49)
    local currentSpeed = Vector4.Length2D(wallState.player:GetVelocity())
    wallState.safeRollSpeed = math.max(fallSpeed, currentSpeed)
end

--- Clear the crouch buffer without triggering a roll (used for short falls).
function SafeLanding.clearBuffer()
    wallState.crouchBuffered = false
    wallState.crouchBufferTimer = 0
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

--- Update the safe roll animation each frame: teleport forward with collision and apply camera pitch spin.
--- @param dt number Delta time in seconds.
--- @return boolean True if a roll is actively in progress.
function SafeLanding.updateRoll(dt)
    if not wallState.safeRollTimer then return false end

    wallState.safeRollTimer = wallState.safeRollTimer + dt
    local t = wallState.safeRollTimer / wallState.safeRollDuration

    if t < 1.0 then
        -- Hide player mesh at 15%
        if not wallState.safeRollMeshIsHidden and t >= 0.15 then
            Helpers.hideCharacterModel()
            wallState.safeRollMeshIsHidden = true
        end
        -- Restore player mesh at 70% (includes slot reattach for skeleton fix)
        if wallState.safeRollMeshIsHidden and t >= 0.7 then
            Helpers.showCharacterModel()
            wallState.safeRollMeshIsHidden = false
            -- Restore weapon meshes before re-equip
            Helpers.showWeaponModel()
            -- Re-equip weapon
            if wallState.safeRollShouldReequip then
                local equipReq = NewObject("EquipmentSystemWeaponManipulationRequest")
                equipReq.requestType = EquipmentManipulationAction.ReequipWeapon
                equipReq.owner = wallState.player
                Game.GetScriptableSystemsContainer():Get(CName.new("EquipmentSystem")):QueueRequest(equipReq)
                wallState.safeRollShouldReequip = false
            end
        end
        -- Teleport forward each frame with collision check
        local d = wallState.safeRollDir
        if d then
            local move = wallState.safeRollSpeed * dt
            local pos = wallState.player:GetWorldPosition()
            local origin = Vector4.new(pos.x, pos.y, pos.z + 0.5, 0)
            local hit, _, hitDist = Helpers.raycast(origin, d, move + 0.3)
            if hit then
                move = math.max(0, hitDist - 0.3)
            end
            if move > 0 then
                local nx, ny = pos.x + d.x * move, pos.y + d.y * move
                local above = Vector4.new(nx, ny, pos.z + 1.0, 0)
                local down = Vector4.new(0, 0, -1, 0)
                local gHit, gPos = Helpers.raycast(above, down, 2.5)
                local nz = gHit and gPos.z or pos.z
                Game.GetTeleportationFacility():Teleport(
                    wallState.player,
                    Vector4.new(nx, ny, nz, 0),
                    EulerAngles.new(0, 0, wallState.safeRollYaw))
            end
        end
        -- Camera pitch: 0.1s delay then full 360-degree forward roll
        -- Ease-in-out: slow at start and end, fast in the middle
        local delay = 0.1
        local elapsed = wallState.safeRollTimer
        local pitch = 0
        if elapsed > delay then
            local spinT = (elapsed - delay) / (wallState.safeRollDuration - delay)
            -- Smoothstep ease-in-out: 3t^2 - 2t^3
            local eased = Helpers.smoothstep(spinT)
            pitch = -eased * 360.0
        end
        local camComp = wallState.player:GetFPPCameraComponent()
        if camComp then
            local quat = EulerAngles.ToQuat(EulerAngles.new(0, pitch, 0))
            camComp:SetLocalOrientation(quat)
        end
    else
        -- Roll complete — store speed for exit impulse at uncrouch
        wallState.safeRollExitSpeed = math.min(20.0, wallState.safeRollSpeed * 0.5)
        wallState.safeRollTimer = nil
        -- Start uncrouch → sprint sequence (no delay — immediate)
        wallState.safeRollUncrouch = 0.01
        -- Reset camera orientation
        local camComp = wallState.player:GetFPPCameraComponent()
        if camComp then
            local quat = EulerAngles.ToQuat(EulerAngles.new(0, 0, 0))
            camComp:SetLocalOrientation(quat)
        end
    end
    return true
end

--- Update the uncrouch and sprint-resume sequence after the safe roll completes.
--- @param dt number Delta time in seconds.
function SafeLanding.updateUncrouch(dt)
    if wallState.safeRollUncrouch then
        -- Keep teleporting forward during uncrouch to prevent momentum gap
        local d = wallState.safeRollDir
        if d and wallState.safeRollExitSpeed then
            local move = wallState.safeRollExitSpeed * dt
            local pos = wallState.player:GetWorldPosition()
            local origin = Vector4.new(pos.x, pos.y, pos.z + 0.5, 0)
            local hit, _, hitDist = Helpers.raycast(origin, d, move + 0.3)
            if hit then
                move = math.max(0, hitDist - 0.3)
            end
            if move > 0 then
                local nx, ny = pos.x + d.x * move, pos.y + d.y * move
                local above = Vector4.new(nx, ny, pos.z + 1.0, 0)
                local down = Vector4.new(0, 0, -1, 0)
                local gHit, gPos = Helpers.raycast(above, down, 2.5)
                local nz = gHit and gPos.z or pos.z
                Game.GetTeleportationFacility():Teleport(
                    wallState.player,
                    Vector4.new(nx, ny, nz, 0),
                    EulerAngles.new(0, 0, wallState.safeRollYaw))
            end
        end

        wallState.safeRollUncrouch = wallState.safeRollUncrouch - dt
        if wallState.safeRollUncrouch <= 0 then
            -- Remove ForceCrouch status effect
            StatusEffectHelper.RemoveStatusEffect(wallState.player,
                TweakDBID.new("GameplayRestriction.ForceCrouch"))
            -- Clear CrouchToggled via Redscript hook
            local qs = Game.GetQuestsSystem()
            if qs then qs:SetFact(CName.new("wr_uncrouch"), 1) end
            wallState.safeRollUncrouch = nil
            Helpers.playSound("ono_v_effort_short")
            -- Fire exit impulse + force sprint simultaneously
            if d and wallState.safeRollExitSpeed then
                local spd = wallState.safeRollExitSpeed
                local imp = PSMImpulse.new()
                imp.id = "impulse"
                imp.impulse = Vector4.new(d.x * spd, d.y * spd, 0, 0)
                wallState.player:QueueEvent(imp)
            end
            wallState.safeRollExitSpeed = nil
            wallState.safeRollDir = nil
            local qs2 = Game.GetQuestsSystem()
            if qs2 then qs2:SetFact(CName.new("wr_sprint"), 1) end
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
