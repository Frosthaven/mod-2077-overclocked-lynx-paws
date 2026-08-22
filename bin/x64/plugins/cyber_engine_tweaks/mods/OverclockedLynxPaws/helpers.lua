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

--- Cast a ray from origin along direction for a given distance.
--- Primary pass uses the "Bullet logic" preset (Static, Terrain, Vehicle, NPC,
--- etc.); fallback passes target collision groups the preset misses so devices
--- (vending machines, terminals, kiosks) and edge-case vehicle colliders can
--- act as walls. First hit wins; non-hits add ~1 µs each.
--- @param origin Vector4 World-space start position.
--- @param direction Vector4 Normalized direction vector.
--- @param distance number Maximum ray distance in meters.
--- @return boolean hit Whether the ray intersected geometry.
--- @return Vector4|nil hitPos World-space hit position, or nil on miss.
--- @return number hitDist Distance to hit point, or 999 on miss.
function Helpers.raycast(origin, direction, distance)
    local to = vectorAdd(origin, vectorMulFloat(direction, distance))
    local sqs = Game.GetSpatialQueriesSystem()

    local hit, trace = sqs:SyncRaycastByQueryPreset(
        origin, to, CName.new("Bullet logic"), true, false
    )
    if not hit then
        hit, trace = sqs:SyncRaycastByCollisionGroup(
            origin, to, CName.new("Interaction"), false, false
        )
    end
    if not hit then
        hit, trace = sqs:SyncRaycastByCollisionGroup(
            origin, to, CName.new("Vehicle"), false, false
        )
    end
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
--- Mouse: CameraMouseX arrives pre-scaled by vanilla FPP_MouseX; our slider is
--- a relative multiplier on top (slider=1.0 matches pre-slider behavior).
--- Controller: stick is raw -1..1; we apply our own sensitivity directly.
--- @param dt number Delta time in seconds.
--- @return number Yaw delta in degrees.
function Helpers.consumeAimYaw(dt)
    local mouseYaw = camera.pendingMouseDeltaX * 0.075 * cfg.lookSensMouseX
    local padYaw = camera.rightStickX * cfg.lookSensControllerX * 10.0 * dt
    camera.pendingMouseDeltaX = 0
    return mouseYaw + padYaw
end

--- Apply camera roll to the player's first-person camera component.
--- Pitch stays 0 so the engine's aim-pitch drives camera AND weapon together.
--- @param roll number The roll angle in degrees (positive tilts left).
function Helpers.applyCameraRoll(roll)
    local camComp = wallState.player:GetFPPCameraComponent()
    if camComp then
        local quat = EulerAngles.ToQuat(EulerAngles.new(-roll, 0, 0))
        camComp:SetLocalOrientation(quat)
    end
end

--- Scale look (pitch) sensitivity during wall phases WITHOUT touching the player's
--- FPP_MouseY / FPP_PadY settings. The engine applies the player's own sensitivity as
--- the base; this layers our multiplier on top via the camera's native sensitivityMultY
--- (carried by SetCameraParamsWithOverridesEvent), so camera AND weapon aim stay coupled.
--- paramsName="" + permissive limits override only the sensitivity, not the camera's
--- params or angle range. multY = 1.0 restores normal. Cheap enough to re-assert every
--- wall frame so the engine's own per-state camera-param updates can't stomp it.
--- @param multY number Pitch sensitivity multiplier (1.0 = unchanged).
function Helpers.applyWallCamSens(multY)
    pcall(function()
        local evt = SetCameraParamsWithOverridesEvent.new()
        evt.paramsName = CName.new("")
        evt.sensitivityMultX = 1.0   -- yaw is driven by the mod directly; leave engine yaw unscaled
        evt.sensitivityMultY = multY
        evt.yawMaxLeft  = 180.0
        evt.yawMaxRight = -180.0
        evt.pitchMax = 89.0
        evt.pitchMin = -89.0
        wallState.player:QueueEvent(evt)
    end)
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

    local highestHitH
    for h = -0.5, 1.2, 0.2 do
        local testOrigin = Vector4.new(pos.x, pos.y, pos.z + h, 0)
        if Helpers.raycast(testOrigin, wallDir, rayLen) then
            highestHitH = h
        end
    end
    if not highestHitH then return nil end

    local candidateH = highestHitH + 0.2
    if candidateH <= 0 then return nil end

    -- Use the same reach as the wall scan above (rayLen) so a wall detected at
    -- 1.0–2.6m (e.g. angled climbs where the player isn't held at targetWallDist)
    -- is correctly seen to continue — otherwise a tall wall looks like it ended
    -- at the candidate and we falsely mount mid-wall.
    local resumeRange = rayLen
    for dh = 0.1, 1.4, 0.1 do
        local upOrigin = Vector4.new(pos.x, pos.y, pos.z + candidateH + dh, 0)
        if Helpers.raycast(upOrigin, wallDir, resumeRange) then
            return nil
        end
    end

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

local OVERHANG_MAX_DEPTH     = 1.125 -- how far the lip may stick out past the player's column (half character height +25%)
local OVERHANG_PROBE_STEP    = 0.075 -- outward probe spacing (15 probes; the last one lands exactly on MAX_DEPTH)
local OVERHANG_MAX_THICKNESS = 1.0   -- lip underside -> top
local OVERHANG_SWING_OUT     = 0.5   -- extra outward clearance past the lip edge (capsule radius + margin)
local OVERHANG_LAND_INSET    = 0.7   -- how far in from the lip edge we land
local OVERHANG_BODY_HEIGHTS  = { 0.3, 1.0, 1.7 }  -- knee / hip / head probe heights for corridor checks

--- When a wall climb's head ray hits the underside of a protruding ledge
--- (balcony lip, cornice, roof edge), work out whether the lip is shallow
--- enough to swing around and over: find its outer edge, its top surface, the
--- clear corridors we move through, and a landing spot on top. Every step is a
--- reject-on-doubt check so we never commit to a path that would push the
--- capsule through geometry.
--- @param pos Vector4 Player world position (feet).
--- @param wallNormal Vector4 Wall surface normal (XY), pointing away from the wall toward the player.
--- @param ceilZ number World Z of the underside hit above the player's head.
--- @return table|nil { edge, topZ, landZ, outOffset, landOffset } (offsets along wallNormal from pos), or nil.
function Helpers.findOverhangTop(pos, wallNormal, ceilZ)
    local n = wallNormal
    local up = Vector4.new(0, 0, 1, 0)
    local down = Vector4.new(0, 0, -1, 0)
    local inward = Vector4.new(-n.x, -n.y, 0, 0)
    local function at(offset, z)
        return Vector4.new(pos.x + n.x * offset, pos.y + n.y * offset, z, 0)
    end

    -- 1. Outer edge: step outward until an upward probe from HIP height finds
    --    nothing between us and the top of the thickest lip we accept. Starting
    --    low (not just under ceilZ) means a sloped or stepped underside that
    --    dips below ceilZ further out still reads as "covered" instead of
    --    letting the probe start inside the lip. Any hit up there (lip or
    --    otherwise) is conservatively "still covered".
    local edge
    local probeZ = pos.z + 1.0
    local probeLen = (ceilZ + OVERHANG_MAX_THICKNESS) - probeZ
    local probeCount = math.floor(OVERHANG_MAX_DEPTH / OVERHANG_PROBE_STEP + 0.5)
    for i = 1, probeCount do
        local d = i * OVERHANG_PROBE_STEP
        if not Helpers.raycast(at(d, probeZ), up, probeLen) then
            edge = d
            break
        end
    end
    if not edge then return nil end

    -- 2. Lip top: drop a ray from above, just inside the edge.
    local topOrigin = at(edge - 0.15, ceilZ + OVERHANG_MAX_THICKNESS + 0.3)
    local hitTop, topPos = Helpers.raycast(topOrigin, down, OVERHANG_MAX_THICKNESS + 0.5)
    if not hitTop or topPos.z < ceilZ or (topPos.z - ceilZ) > OVERHANG_MAX_THICKNESS then
        return nil
    end
    local topZ = topPos.z

    -- 3. Swing-out corridor: from our column straight out to the swing point,
    --    at knee, hip and head height. The capsule moves at constant Z here
    --    (still under the lip), so this is exactly the space it sweeps.
    local outOffset = edge + OVERHANG_SWING_OUT
    for _, h in ipairs(OVERHANG_BODY_HEIGHTS) do
        if Helpers.raycast(at(0, pos.z + h), n, outOffset + 0.1) then return nil end
    end

    -- 4. Rise column outside the edge: from knee height up to standing height
    --    above the lip (no second overhang, nothing above the lip edge).
    local colLen = (topZ + 0.3 + 1.8) - (pos.z + 0.3)
    if Helpers.raycast(at(outOffset, pos.z + 0.3), up, colLen) then return nil end

    -- 5. Landing: on top of the lip, inset from the edge, with head room.
    local landOffset = edge - OVERHANG_LAND_INSET
    local hitLand, landPos = Helpers.raycast(at(landOffset, topZ + 0.6), down, 1.2)
    if not hitLand or landPos.z < ceilZ then return nil end
    local landZ = landPos.z + 0.1
    if Helpers.raycast(at(landOffset, landZ + 0.3), up, 1.6) then return nil end

    -- 6. Pull-in corridor: from the risen point back in over the lip to the
    --    landing, at knee/hip/head above the lip top. Catches a railing, post
    --    or wall standing on the lip between its edge and where we land.
    local pullLen = (outOffset - landOffset) + 0.1
    local baseZ = math.max(topZ + 0.3, landZ)
    for _, h in ipairs(OVERHANG_BODY_HEIGHTS) do
        if Helpers.raycast(at(outOffset, baseZ + h), inward, pullLen) then return nil end
    end

    return {
        edge = edge, topZ = topZ, landZ = landZ,
        outOffset = outOffset, landOffset = landOffset,
    }
end

--- Reset camera roll to zero (tilt, targetTilt, rollBlendProgress, and apply).
function Helpers.resetCameraRoll()
    camera.tilt = 0
    camera.targetTilt = 0
    camera.rollBlendProgress = 0
    Helpers.applyCameraRoll(0)
end

--- Full camera hand-back: roll bookkeeping to zero, then position AND
--- orientation on the FPP component to identity. Used on shutdown and master
--- toggle off, where a safe roll's -0.7m drop or pitch spin may be mid-flight.
--- pcall'd because both paths can run while the player entity is tearing down.
function Helpers.resetCameraTransform()
    camera.tilt = 0
    camera.targetTilt = 0
    camera.rollBlendProgress = 0
    if not wallState.player then return end
    pcall(function()
        local camComp = wallState.player:GetFPPCameraComponent()
        if camComp then
            camComp:SetLocalPosition(Vector4.new(0, 0, 0, 0))
            camComp:SetLocalOrientation(EulerAngles.ToQuat(EulerAngles.new(0, 0, 0)))
        end
    end)
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
