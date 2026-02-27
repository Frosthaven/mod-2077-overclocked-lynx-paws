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

--- Queue a sound play event on the player entity.
--- @param name string The sound event name to play.
function Helpers.playSound(name)
    local evt = SoundPlayEvent.new()
    evt.soundName = name
    wallState.player:QueueEvent(evt)
end

--- Queue a sound stop event on the player entity.
--- @param name string The sound event name to stop.
function Helpers.stopSound(name)
    local evt = SoundStopEvent.new()
    evt.soundName = name
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

--- Consume pending mouse and gamepad right-stick input to compute a yaw delta.
--- @param dt number Delta time in seconds.
--- @return number The computed yaw delta in degrees.
function Helpers.consumeAimYaw(dt)
    local baseSens = 0.075
    local sens = baseSens * cfg.aimSensitivity
    local yawDelta = camera.pendingMouseDeltaX * sens + camera.rightStickX * sens * 120.0 * dt
    camera.pendingMouseDeltaX = 0
    return yawDelta
end

--- Apply a camera roll angle to the player's first-person camera component.
--- @param roll number The roll angle in degrees (positive tilts left).
function Helpers.applyCameraRoll(roll)
    local camComp = wallState.player:GetFPPCameraComponent()
    if camComp then
        local quat = EulerAngles.ToQuat(EulerAngles.new(-roll, 0, 0))
        camComp:SetLocalOrientation(quat)
    end
end

--- Cast a ray from hip height, falling back to knee height on miss.
--- @param pos Vector4 The player's world position (feet level).
--- @param rayDir Vector4 Normalized direction to cast.
--- @param range number Maximum ray distance in meters.
--- @return boolean hit Whether either ray intersected geometry.
--- @return Vector4|nil hitPos World-space hit position, or nil on miss.
--- @return number hitDist Distance to hit point, or 999 on miss.
function Helpers.raycastWithKneeFallback(pos, rayDir, range)
    local hipOrigin = Vector4.new(pos.x, pos.y, pos.z + 1.0, 0)
    local hit, hitPos, dist = Helpers.raycast(hipOrigin, rayDir, range)
    if not hit then
        local kneeOrigin = Vector4.new(pos.x, pos.y, pos.z + 0.4, 0)
        hit, hitPos, dist = Helpers.raycast(kneeOrigin, rayDir, range)
    end
    return hit, hitPos, dist
end

--- Scan upward from the player's position to find where a wall ends (ledge top).
--- @param pos Vector4 The player's world position.
--- @param wallNormal Vector4 The wall surface normal (XY plane).
--- @return number|nil ledgeZ The Z height of the ledge top, or nil if the wall is too tall.
function Helpers.findLedgeTop(pos, wallNormal)
    local wallDir = Vector4.new(-wallNormal.x, -wallNormal.y, 0, 0)
    for h = -0.5, 1.2, 0.2 do
        local testOrigin = Vector4.new(pos.x, pos.y, pos.z + h, 0)
        local hit = Helpers.raycast(testOrigin, wallDir, cfg.wallDetectDistance * 2)
        if not hit and h > 0 then
            return pos.z + h
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
