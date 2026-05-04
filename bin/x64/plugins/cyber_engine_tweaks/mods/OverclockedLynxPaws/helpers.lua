local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local camera = state.camera

local Helpers = {}

-- Cached game operators (set via Helpers.init)
local vectorAdd, vectorMulFloat

--- Initialize cached game operator references for vector math.
function Helpers.init()
    vectorAdd = Game['OperatorAdd;Vector4Vector4;Vector4']
    vectorMulFloat = Game['OperatorMultiply;Vector4Float;Vector4']
end

local lastLocomotionState = 0

--- Return the last cached detailed locomotion state value.
--- @return number The locomotion state integer from the previous isAirDashing call.
function Helpers.getLastLocomotionState()
    return lastLocomotionState
end

--- Print a debug message to the CET console if CET logging is enabled.
--- @param msg string The message to print.
function Helpers.logDebug(msg)
    if cfg.cetLogsEnabled then print(msg) end
end

--- Query the player state machine blackboard for the detailed locomotion state.
--- @return number The current gamePSMDetailedLocomotionStates integer value, or 0 on failure.
function Helpers.getDetailedLocomotionState()
    local bb = Helpers.getPlayerBlackboard()
    if not bb then return 0 end
    local ok, result = pcall(function()
        return bb:GetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.LocomotionDetailed)
    end)
    return ok and result or 0
end

--- Check whether the player is currently airborne (jump, double jump, charge jump, or fall).
--- @return boolean True if the player is in any airborne locomotion state.
function Helpers.isAirborne()
    local s = Helpers.getDetailedLocomotionState()
    return s == EnumInt(gamePSMDetailedLocomotionStates.Jump)
        or s == EnumInt(gamePSMDetailedLocomotionStates.DoubleJump)
        or s == EnumInt(gamePSMDetailedLocomotionStates.ChargeJump)
        or s == EnumInt(gamePSMDetailedLocomotionStates.Fall)
end

--- Check whether the player is currently air dashing and cache the locomotion state.
--- @return boolean True if the detailed locomotion state equals 7 (air dash).
function Helpers.isAirDashing()
    local s = Helpers.getDetailedLocomotionState()
    lastLocomotionState = s
    return s == 7
end

--- Check whether the player's horizontal speed exceeds the minimum threshold for wall actions.
--- @return boolean True if the player's 2D velocity magnitude is above 5.3 m/s.
function Helpers.meetsMinimumSpeed()
    return Vector4.Length2D(wallState.player:GetVelocity()) > 5.3
end

--- Cast a ray from origin along direction for a given distance using bullet logic preset.
--- @param origin Vector4 World-space start position.
--- @param direction Vector4 Normalized direction vector.
--- @param distance number Maximum ray distance in meters.
--- @return boolean hit Whether the ray intersected geometry.
--- @return Vector4|nil hitPos World-space hit position, or nil on miss.
--- @return number hitDist Distance to hit point, or 999 on miss.
function Helpers.raycast(origin, direction, distance)
    local to = vectorAdd(origin, vectorMulFloat(direction, distance))
    local hit, trace = Game.GetSpatialQueriesSystem():SyncRaycastByQueryPreset(
        origin, to, CName.new("Bullet logic"), true, false
    )
    if hit then
        local hp = Vector4.new(
            trace.position.x, trace.position.y, trace.position.z, 0
        )
        return true, hp, Vector4.Distance(origin, hp)
    end
    return false, nil, 999
end

--- Spawn a wall impact VFX at the given world position using FxSystem.
--- @param position Vector4 World-space position for the effect.
function Helpers.spawnWallImpactVFX(position)
    pcall(function()
        local fxSystem = Game.GetFxSystem()
        local transform = WorldTransform.new()
        transform:SetPosition(position)
        fxSystem:SpawnEffect(gameFxResource.new({ effect = "base\\fx\\quest\\q101\\q101_06c_memories_p2\\q101_impact_concrete.effect" }), transform)
        fxSystem:SpawnEffect(gameFxResource.new({ effect = "base\\fx\\weapons\\impacts\\concrete\\large_cal\\imp_concrete_refl_lc.effect" }), transform)
        fxSystem:SpawnEffect(gameFxResource.new({ effect = "base\\fx\\weapons\\tech\\_impacts\\piercing\\t_impact_concrete_piercing.effect" }), transform)
        fxSystem:SpawnEffect(gameFxResource.new({ effect = "base\\fx\\weapons\\impacts\\_common\\power\\imp_power_default_piercing_decal.effect" }), transform)
    end)
end

-- Cybernetic → natural sound replacements (when cfg.useNaturalSounds is on).
local naturalSoundMap = {
    ["lcm_wallrun_in"]                = "lcm_fs_heavy_boots_tarmac_land",
    ["lcm_wallrun_out"]               = "lcm_fs_heavy_boots_metal_grating_jump",
    ["lcm_player_double_jump"]        = "lcm_fs_heavy_boots_metal_grating_jump",
    ["w_gun_pistol_tech_kenshin_charge"] = "test_sound",
}

--- Apply the natural-sound override if the setting is enabled.
--- @param name string Original sound name.
--- @return string The remapped name (or the original if no remap).
local function remapSound(name)
    if cfg.useNaturalSounds and naturalSoundMap[name] then
        return naturalSoundMap[name]
    end
    return name
end

--- Queue a sound play event on the player entity.
--- @param name string The sound event name to play.
function Helpers.playSound(name)
    local evt = SoundPlayEvent.new()
    evt.soundName = remapSound(name)
    wallState.player:QueueEvent(evt)
end

--- Queue a sound stop event on the player entity.
--- @param name string The sound event name to stop.
function Helpers.stopSound(name)
    local evt = SoundStopEvent.new()
    evt.soundName = remapSound(name)
    wallState.player:QueueEvent(evt)
end

--- Queue a PSM impulse event on the player to apply an instantaneous velocity change.
--- @param vec Vector4 The impulse vector to apply.
function Helpers.queueImpulse(vec)
    local imp = PSMImpulse.new()
    imp.id = "impulse"
    imp.impulse = vec
    wallState.player:QueueEvent(imp)
end

local hiddenPlayerMeshes = {}
local hiddenWeaponComponents = {}

--- Hide the player character model by disabling all active mesh components and weapon meshes.
function Helpers.hideCharacterModel()
    hiddenPlayerMeshes = {}
    hiddenWeaponComponents = {}
    -- Hide player mesh components
    local comps = wallState.player:GetComponents()
    for _, comp in ipairs(comps) do
        if string.find(NameToString(comp:GetClassName()), "Mesh") and comp:IsEnabled() then
            comp:Toggle(false)
            hiddenPlayerMeshes[NameToString(comp:GetName())] = true
        end
    end
    -- Hide weapon item meshes
    local ts = Game.GetTransactionSystem()
    if ts then
        for _, slotName in ipairs({"AttachmentSlots.WeaponRight", "AttachmentSlots.WeaponLeft"}) do
            pcall(function()
                local item = ts:GetItemInSlot(wallState.player, TweakDBID.new(slotName))
                if item then
                    local wComps = item:GetComponents()
                    for _, comp in ipairs(wComps) do
                        if string.find(NameToString(comp:GetClassName()), "Mesh") and comp:IsEnabled() then
                            comp:Toggle(false)
                            table.insert(hiddenWeaponComponents, comp)
                        end
                    end
                end
            end)
        end
    end
end

--- Restore previously hidden player mesh components back to visible.
function Helpers.showCharacterModel()
    local comps = wallState.player:GetComponents()
    for _, comp in ipairs(comps) do
        if hiddenPlayerMeshes[NameToString(comp:GetName())] then
            comp:Toggle(true)
        end
    end
    hiddenPlayerMeshes = {}
end

--- Restore previously hidden weapon mesh components back to visible.
function Helpers.showWeaponModel()
    for _, comp in ipairs(hiddenWeaponComponents) do
        pcall(function() comp:Toggle(true) end)
    end
    hiddenWeaponComponents = {}
end

--- Queue a wall kick impulse and set up chain scan state for wall-to-wall chaining.
--- @param kickVec Vector4 The kick impulse vector to apply on the next frame.
function Helpers.queueWallKick(kickVec)
    wallState.pendingKickImpulse = kickVec
    wallState.chainScanTimer = 0
    wallState.chainScanDirection = Vector4.Normalize(Vector4.new(kickVec.x, kickVec.y, 0, 0))
end

--- Get the player's PSM blackboard for reading/writing locomotion and body state.
--- @return IBlackboard|nil The player state machine blackboard, or nil on failure.
function Helpers.getPlayerBlackboard()
    local ok, bb = pcall(function()
        return Game.GetBlackboardSystem():GetLocalInstanced(
            wallState.player:GetEntityID(),
            Game.GetAllBlackboardDefs().PlayerStateMachine
        )
    end)
    return ok and bb or nil
end

--- Get the player's approximate hip-height world position (1m above feet).
--- @return Vector4 The hip-level position vector.
function Helpers.getPlayerHipPosition()
    local pos = wallState.player:GetWorldPosition()
    return Vector4.new(pos.x, pos.y, pos.z + 1.0, 0)
end

--- Get the camera's right direction flattened to the XY plane and normalized.
--- @return Vector4 The horizontal right-facing direction vector.
function Helpers.getCameraRightDirection()
    local cr = Game.GetCameraSystem():GetActiveCameraRight()
    return Vector4.Normalize(Vector4.new(cr.x, cr.y, 0, 0))
end

--- Resolve which input source to consult for a given action.
--- If a CET hotkey is bound for the action, only the hotkey's just-pressed
--- flag fires the action; otherwise fall back to the original key/chord
--- detection. Lets users rebind reverse hang / dismount / safe-roll without
--- breaking the default UX.
--- @param boundFlag boolean Cached IsBound() result for the hotkey.
--- @param customFlag boolean The hotkey's just-pressed input flag.
--- @param originalCondition boolean The original detection (back+jump, crouch, etc).
--- @return boolean True if the action should fire this frame.
function Helpers.actionFired(boundFlag, customFlag, originalCondition)
    if boundFlag then return customFlag end
    return originalCondition
end

--- Compute smoothstep (Hermite) interpolation: 3t^2 - 2t^3, clamped to [0,1].
--- @param t number Input value (typically 0 to 1).
--- @return number The smoothstepped value.
function Helpers.smoothstep(t)
    t = math.max(0, math.min(1, t))
    return t * t * (3.0 - 2.0 * t)
end

--- Linearly interpolate an angle toward a target at a given speed, snapping when close.
--- @param current number The current angle in degrees.
--- @param target number The target angle in degrees.
--- @param speed number The interpolation speed factor.
--- @param dt number Delta time in seconds.
--- @return number The interpolated angle value.
function Helpers.lerpAngle(current, target, speed, dt)
    local diff = target - current
    local step = diff * math.min(1.0, speed * dt)
    if math.abs(diff) < 0.1 then return target end
    return current + step
end

--- Interpolate between two angles using shortest-path wrapping around 360 degrees.
--- @param a number Start angle in degrees.
--- @param b number End angle in degrees.
--- @param t number Interpolation factor (0 to 1).
--- @return number The interpolated angle value.
function Helpers.angleLerp(a, b, t)
    local diff = ((b - a + 180) % 360) - 180
    return a + diff * t
end

--- Manually drive aim assist during teleport-driven wall phases.
--- Engine's aim assist tick is bypassed because we own the player transform
--- every frame; this replicates vanilla soft-lock by querying the targeting
--- system and nudging camera.trackedYaw toward the candidate target.
--- Respects the player's Aim Assist setting (Off/Light/Standard/Heavy).
--- Only fires while ADS-ing.
--- @param dt number Delta time in seconds.
function Helpers.applyAimAssist(dt)
    local Kerenzikov = require("kerenzikov")
    if not Kerenzikov.isAimingDownSights() then return end

    local strength = 0
    pcall(function()
        local lvlStr = tostring(wallState.player:GetAimAssistLevel())
        if lvlStr:find("Off") then strength = 0
        elseif lvlStr:find("Light") then strength = 30
        elseif lvlStr:find("Heavy") or lvlStr:find("Substantial") then strength = 120
        else strength = 60 end
    end)
    if strength <= 0 then return end

    -- Find a target via the engine's targeting system, then walk to the
    -- parent entity for a usable world position. GetComponentClosestToCrosshair
    -- returns an IPlacedComponent whose owner is the GameObject we want.
    local tgtPos
    pcall(function()
        local q = TSQ_EnemyNPC()
        q.maxDistance = 50.0
        q.filterObjectByDistance = true
        local comp = Game.GetTargetingSystem():GetComponentClosestToCrosshair(wallState.player, q)
        if not comp then return end
        local entity
        pcall(function() entity = comp:GetEntity() end)
        if not entity then
            pcall(function() entity = comp:GetOwner() end)
        end
        if entity then tgtPos = entity:GetWorldPosition() end
    end)
    if not tgtPos then return end

    -- Wrap the camera/math/correction in pcall so a runtime error here can
    -- never propagate up and break the wall-phase teleport pipeline.
    pcall(function()
        -- Approximate camera world position from the player + head-height
        -- offset; CameraSystem doesn't expose a world-position getter.
        local pp = wallState.player:GetWorldPosition()
        local camPos = Vector4.new(pp.x, pp.y, pp.z + 1.6, 0)
        local fwd = Game.GetCameraSystem():GetActiveCameraForward()
        local dx = tgtPos.x - camPos.x
        local dy = tgtPos.y - camPos.y
        local dz = (tgtPos.z + 1.0) - camPos.z
        local horizLen = math.sqrt(dx*dx + dy*dy)
        if horizLen < 0.1 then return end

        local fwdYaw = math.deg(math.atan2(fwd.y, fwd.x))
        local tgtYaw = math.deg(math.atan2(dy, dx))
        local yawErr = ((tgtYaw - fwdYaw + 180) % 360) - 180

        local fwdPitch = math.deg(math.atan2(fwd.z, math.sqrt(fwd.x*fwd.x + fwd.y*fwd.y)))
        local tgtPitch = math.deg(math.atan2(dz, horizLen))
        local pitchErr = tgtPitch - fwdPitch

        local maxYaw, maxPitch = 8.0, 5.0
        if math.abs(yawErr) > maxYaw or math.abs(pitchErr) > maxPitch then return end

        local falloff = 1.0 - math.min(1.0, math.abs(yawErr) / maxYaw)
        local correction = math.min(strength * falloff * dt, math.abs(yawErr))
        if yawErr > 0 then
            camera.trackedYaw = camera.trackedYaw + correction
        else
            camera.trackedYaw = camera.trackedYaw - correction
        end
    end)
end

--- Consume pending mouse and gamepad right-stick X input to compute a yaw delta.
--- Mouse: CameraMouseX arrives pre-scaled by vanilla FPP_MouseX. We divide that
--- out so the mod's slider becomes the authoritative wall-phase mouse sensitivity.
--- Controller: stick is raw -1..1; we apply our own sensitivity directly (no read
--- of vanilla FPP_PadX).
--- @param dt number Delta time in seconds.
--- @return number Yaw delta in degrees.
function Helpers.consumeAimYaw(dt)
    local ss = Game.GetSettingsSystem()
    local vMouseX = ss:GetVar("/controls/fppcameramouse", "FPP_MouseX")
    local vSensX = (vMouseX and vMouseX:GetValue()) or 1.0
    local rawX = camera.pendingMouseDeltaX / math.max(0.01, vSensX)
    local mouseYaw = rawX * 0.075 * cfg.lookSensMouseX

    local padYaw = camera.rightStickX * cfg.lookSensControllerX * 10.0 * dt

    camera.pendingMouseDeltaX = 0
    return mouseYaw + padYaw
end

--- Consume pending mouse and gamepad right-stick Y input to compute a pitch delta.
--- Same divide-out-vanilla approach for mouse so the slider is authoritative.
--- Negation aligns "stick/mouse down → look up" with the engine's post-invert convention.
--- @param dt number Delta time in seconds.
--- @return number Pitch delta in degrees (positive = look up).
function Helpers.consumePitch(dt)
    local ss = Game.GetSettingsSystem()
    local vMouseY = ss:GetVar("/controls/fppcameramouse", "FPP_MouseY")
    local vSensY = (vMouseY and vMouseY:GetValue()) or 1.0
    local rawY = camera.pendingMouseDeltaY / math.max(0.01, vSensY)
    local mousePitch = -rawY * 0.075 * cfg.lookSensMouseY

    local padPitch = -camera.rightStickY * cfg.lookSensControllerY * 10.0 * dt

    camera.pendingMouseDeltaY = 0
    return mousePitch + padPitch
end

--- Apply camera roll AND tracked pitch to the player's first-person camera component.
--- Combined into one SetLocalOrientation so we don't double-write per frame.
--- @param roll number The roll angle in degrees (positive tilts left).
function Helpers.applyCameraRoll(roll)
    local camComp = wallState.player:GetFPPCameraComponent()
    if camComp then
        local quat = EulerAngles.ToQuat(EulerAngles.new(-roll, camera.trackedPitch, 0))
        camComp:SetLocalOrientation(quat)
    end
end

--- Cast a ray at multiple body heights, returning the first hit.
--- The dense low-range probes (0.40 → 0.65 at 0.05 m spacing) are tuned to
--- catch slatted fences with periods 0.15–0.50 m and plank thickness ≥ 5 cm
--- — six probes give six distinct offsets per 0.30 m period, so at least
--- one always lands in plank material. The upper probes provide body-height
--- coverage for non-slat walls. Early-exit on first hit keeps cost ~1 ray
--- per frame on solid walls.
--- @param pos Vector4 The player's world position (feet level).
--- @param rayDir Vector4 Normalized direction to cast.
--- @param range number Maximum ray distance in meters.
--- @return boolean hit Whether any ray intersected geometry.
--- @return Vector4|nil hitPos World-space hit position, or nil on miss.
--- @return number hitDist Distance to hit point, or 999 on miss.
function Helpers.raycastWithKneeFallback(pos, rayDir, range)
    local heights = {
        1.0, 0.4,                                      -- original hip + knee tried first
        0.45, 0.5, 0.55, 0.6, 0.65,                    -- dense slat-busting probes
        0.75, 0.85, 0.95, 1.05, 1.15, 1.25, 1.3,       -- upper-body coverage
    }
    for _, h in ipairs(heights) do
        local origin = Vector4.new(pos.x, pos.y, pos.z + h, 0)
        local hit, hitPos, dist = Helpers.raycast(origin, rayDir, range)
        if hit then return hit, hitPos, dist end
    end
    return false, nil, 999
end

--- Scan upward from the player's position to find where a wall ends (ledge top).
--- @param pos Vector4 The player's world position.
--- @param wallNormal Vector4 The wall surface normal (XY plane).
--- @return number|nil ledgeZ The Z height of the ledge top, or nil if the wall is too tall.
function Helpers.findLedgeTop(pos, wallNormal)
    local wallDir = Vector4.new(-wallNormal.x, -wallNormal.y, 0, 0)
    local rayLen = cfg.wallDetectDistance * 2

    -- Find the highest h within scan range where the wall hits. The mount
    -- candidate sits one scan-step above this so we always land above the
    -- wall's actual topmost surface — never inside a slat gap on a thin
    -- fence and never on a fake ledge in a hole/window.
    local highestHitH
    for h = -0.5, 1.2, 0.2 do
        local testOrigin = Vector4.new(pos.x, pos.y, pos.z + h, 0)
        if Helpers.raycast(testOrigin, wallDir, rayLen) then
            highestHitH = h
        end
    end
    if not highestHitH then return nil end

    -- Candidate ledge top must be above the player's feet to be reachable.
    local candidateH = highestHitH + 0.2
    if candidateH <= 0 then return nil end

    -- Verify wall doesn't continue above the candidate. Dense 10 cm sweep
    -- catches slatted-fence plank patterns whose period the previous
    -- {0.4, 0.8, 1.4} sampling could alias through.
    local resumeRange = cfg.targetWallDist + 0.4
    for dh = 0.1, 1.4, 0.1 do
        local upOrigin = Vector4.new(pos.x, pos.y, pos.z + candidateH + dh, 0)
        if Helpers.raycast(upOrigin, wallDir, resumeRange) then
            return nil
        end
    end

    -- Verify any solid surface past the wall (within 20 m below candidate).
    -- Drops the previous ±1 m height tolerance so tall fences on flat ground
    -- still mount — the resume sweep above already verified the candidate is
    -- above the wall structure, and the actual mount animation re-probes for
    -- the landing surface separately. We just need to confirm we're not
    -- mounting over pure void.
    for _, d in ipairs({ 0.5, 0.8, 1.1 }) do
        local pastX = pos.x + wallDir.x * d
        local pastY = pos.y + wallDir.y * d
        local downOrigin = Vector4.new(pastX, pastY, pos.z + candidateH + 0.5, 0)
        if Helpers.raycast(downOrigin, Vector4.new(0, 0, -1, 0), 20.0) then
            return pos.z + candidateH
        end
    end
    return nil
end

--- Reset camera roll to zero (tilt, targetTilt, rollBlendProgress, and apply).
function Helpers.resetCameraRoll()
    camera.tilt = 0
    camera.targetTilt = 0
    camera.rollBlendProgress = 0
    Helpers.applyCameraRoll(0)
end

local footstepInterval = 0.68

--- Advance the footstep timer and play a running footstep sound at regular intervals.
--- @param dt number Delta time in seconds.
--- @param speedMult number|nil Optional speed multiplier for the timer (defaults to 1.0).
function Helpers.playFootsteps(dt, speedMult)
    wallState.footstepTimer = wallState.footstepTimer + dt * (speedMult or 1.0)
    if wallState.footstepTimer >= footstepInterval then
        wallState.footstepTimer = wallState.footstepTimer - footstepInterval
        Helpers.playSound("lcm_fs_sneakers_concrete_run")
    end
end

return Helpers
