local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local camera = state.camera
local ledgeMount = state.ledgeMount
local input = require("input")
local Helpers = require("helpers")
local Kerenzikov = require("kerenzikov")
local WallDetect = require("walldetect")
local SafeLanding = require("safelanding")
local LynxPawMod = require("lynxpaw")
local Debug = require("debug")

local Phases = {}

---------------------------------------------------------------------------
-- Internal constants (not user-facing — use cfg for tunable settings)
---------------------------------------------------------------------------
local SAME_WALL_DOT        = 0.7       -- dot threshold for same-wall rejection (~45°)
local CHAIN_SCAN_WINDOW    = 4.0       -- seconds to scan for chain targets after kick
local DASH_DURATION        = 0.328125  -- air dash phase duration (seconds)
local ARC_HEIGHT           = 9.0       -- vertical arc multiplier during wall kick
local HOVER_DURATION       = 3.0       -- air hover max duration (seconds)
local PEAK_HOLD_DURATION   = 0         -- pause at climb peak before sliding (seconds)
local KICK_ARC_RATIO       = 0.15      -- vertical boost as fraction of kick force (wallKick)
local AIM_KICK_ARC_RATIO   = 0.75      -- vertical boost as fraction of kick force (aim kick)
local RHANG_SCOOP_DEG      = 12        -- pitch scoop amplitude during reverse hang (degrees)
local WALL_RUN_GRACE_DURATION  = 0.25  -- seconds to ride through small wall gaps
local WALL_RUN_VERT_PROBE_OFFSET = 0.8 -- height above/below targetZ to probe wall existence
local WALL_RUN_MIN_SPEED      = 7.0   -- minimum wall run lateral speed (m/s)
local WALL_RUN_SPEED_DECAY    = 2.0   -- seconds for entry speed to decay to minimum

-- Stamina costs (when cfg.drainStamina is enabled)
local STAMINA_WALL_RUN_PER_SEC   = 90  -- per second while wall running
local STAMINA_WALL_CLIMB_PER_SEC = 140 -- per second while wall climbing
local STAMINA_WALL_KICK          = 35  -- flat cost per wall kick / jump
local STAMINA_MIN_TO_START       = 35  -- minimum stamina to enter wall run / climb

---------------------------------------------------------------------------
-- State Machine Transitions:
--
--   IDLE ──────────► WALL_RUNNING ──► WALL_SLIDING ──► IDLE
--     │                  │                 │
--     │                  ▼                 ▼
--     │              WALL_JUMP_AIM    REVERSE_WALL_HANG
--     │                  │                 │
--     │                  ▼                 ▼
--     │              WALL_JUMPING     WALL_JUMP_AIM
--     │                  │
--     │                  ▼
--     ├──────────► EXIT_PUSH ──────► IDLE
--     │
--     └──────────► WALL_CLIMBING ──► WALL_SLIDING
--                      │                 │
--                      ▼                 ▼
--                  LEDGE_MOUNTING    REVERSE_WALL_HANG
--                      │
--                      ▼
--                    IDLE
--
--   AIR_HOVER is entered from EXIT_PUSH when air Kerenzikov perk is active
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Stamina helpers
---------------------------------------------------------------------------
local function getStamina()
    local sps = Game.GetStatPoolsSystem()
    if not sps then return 100 end
    return sps:GetStatPoolValue(wallState.player:GetEntityID(), gamedataStatPoolType.Stamina, false)
end

local function getShinobiLevel()
    local ok, level = pcall(function()
        local sys = Game.GetScriptableSystemsContainer():Get("OverclockedLynxPaws.WallRunSettings")
        return sys:GetShinobiLevel()
    end)
    return (ok and level) or 0
end

local function drainStamina(amount)
    if not cfg.drainStamina or amount <= 0 then return end
    local sps = Game.GetStatPoolsSystem()
    if not sps then return end
    local mult
    if cfg.staminaScalesShinobi then
        -- Reduce cost by up to 80% at Shinobi level 60 (~1.33% per level)
        local level = getShinobiLevel()
        mult = 1.0 - (0.80 * math.min(level, 60) / 60)
    else
        -- Reduce cost by 0-80% based on equipped Lynx Paw tier
        mult = LynxPawMod.getStaminaMultiplier()
    end
    sps:RequestChangingStatPoolValue(wallState.player:GetEntityID(), gamedataStatPoolType.Stamina, -amount * mult, nil, false, false)
end

local function hasEnoughStamina()
    if not cfg.drainStamina then return true end
    return getStamina() > STAMINA_MIN_TO_START
end

---------------------------------------------------------------------------
-- Wall-run lifecycle helpers
---------------------------------------------------------------------------
local function resetFallState()
    local bb = Helpers.getPlayerBlackboard()
    if bb then
        bb:SetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.Fall, 0, true)
        bb:SetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.Landing, 0, true)
    end
end

local function setClimbBlock(block)
    local qs = Game.GetQuestsSystem()
    if qs then qs:SetFact(CName.new("wr_wall_active"), block and 1 or 0) end
end

--- Shared cleanup for all wall exit paths.
local function cleanupWallState()
    Kerenzikov.deactivate()
    Helpers.stopSound("lcm_fs_additional_tiles_slide")
    setClimbBlock(false)
    wallState.climbPeakHoldTimer = nil
    wallState.wallLostTimer = nil
    wallState.phase        = "IDLE"
    wallState.wallSide     = nil
    wallState.wallNormal   = nil
    wallState.wallRunDir   = nil
    wallState.kickDirection = nil
    wallState.timer        = 0
    wallState.cooldown     = 0
end

--- Transition to slide from any wall phase (stamina depletion or timer expiry).
local function transitionToSlide()
    wallState.targetZ = wallState.player:GetWorldPosition().z
    wallState.phase = "WALL_SLIDING"
    wallState.timer = wallState.slideBudget or cfg.wallSlideDuration
    Helpers.playSound("lcm_fs_additional_tiles_slide")
end

local function enterWallRun(side, rayDir, wallNormal, isChain)
    resetFallState()
    wallState.phase    = "WALL_RUNNING"
    wallState.wallSide = side
    wallState.wallNormal = wallNormal or Vector4.new(-rayDir.x, -rayDir.y, 0, 0)
    wallState.wallRunEntryNormal = Vector4.new(wallState.wallNormal.x, wallState.wallNormal.y, 0, 0)
    wallState.wallRunDir = WallDetect.calculateWallRunDirection(wallState.wallNormal)
    wallState.timer      = cfg.wallRunDuration
    wallState.wallRunUsedThisJump = true
    wallState.entryZ     = wallState.player:GetWorldPosition().z
    wallState.targetZ    = wallState.entryZ
    wallState.wallRunEntrySpeed = math.max(Vector4.Length2D(wallState.player:GetVelocity()), WALL_RUN_MIN_SPEED)
    wallState.wallRunElapsed = 0
    wallState.footstepTimer = 0
    camera.targetTilt = (side == "right") and cfg.cameraTilt or -cfg.cameraTilt
    camera.rollBlendProgress = 0
    camera.tilt       = 0
    camera.trackedYaw   = wallState.player:GetWorldYaw()
    camera.pendingMouseDeltaX = 0
    setClimbBlock(true)
    wallState.isClimbBlocked = true
    wallState.wallLostTimer = nil

    if not isChain then Helpers.playSound("lcm_wallrun_in") end
    Kerenzikov.awardShinobiXP(isChain and 7.0 or 5.0)
end

local function exitWallRun()
    wallState.lastKickWallNormal = wallState.wallNormal
    cleanupWallState()
    -- Camera unroll handled by IDLE lerp
    Helpers.playSound("lcm_wallrun_out")
end

local function yieldToGame()
    cleanupWallState()
    wallState.aimHoldZ = nil
    Helpers.resetCameraRoll()
end

local function isSameWall(wallNormal)
    if not wallState.lastKickWallNormal then return false end
    local dot = wallNormal.x * wallState.lastKickWallNormal.x + wallNormal.y * wallState.lastKickWallNormal.y
    return dot > SAME_WALL_DOT
end

-- Forward declarations for mutual references
local enterWallClimb, beginLedgeMount, beginWallJump, beginReverseHang, beginExitPush

local function tryChainWall(kickDir)
    if not cfg.unlimitedWallChains and wallState.chainCount >= cfg.maxWallChains then
        Helpers.logDebug("[Chain] BLOCKED: max chains reached")
        return false
    end

    local vel = wallState.player:GetVelocity()
    -- During WALL_JUMPING the player is teleported, so GetVelocity() is
    -- unreliable.  Prefer the actual kick direction when available.
    if kickDir then
        local speed = math.max(Vector4.Length2D(vel), cfg.wallKickForce)
        vel = Vector4.new(kickDir.x * speed, kickDir.y * speed, vel.z, 0)
    end
    local action, side, rayDir, wallN, deg = WallDetect.classifyWallAction(vel)
    if not action then
        Helpers.logDebug(string.format("[Chain] NO ACTION: velLen=%.1f", Vector4.Length2D(vel)))
        return false
    end
    if isSameWall(wallN) then
        Helpers.logDebug("[Chain] BLOCKED: same wall")
        return false
    end

    wallState.chainCount = wallState.chainCount + 1
    if action == "climb" then
        wallState.wallClimbUsedThisJump = false
        wallState.climbEntryDeg = deg
        enterWallClimb(wallN, true)
        wallState.timer = math.min(wallState.timer + cfg.chainBonusDuration, cfg.wallClimbDuration)
    else
        wallState.wallRunUsedThisJump = false
        enterWallRun(side, rayDir, wallN, true)
        wallState.timer = math.min(wallState.timer + cfg.chainBonusDuration, cfg.wallRunDuration)
    end
    return true
end

beginLedgeMount = function(wallNormal)
    local pos = wallState.player:GetWorldPosition()

    local ledgeZ = Helpers.findLedgeTop(pos, wallNormal)
    if not ledgeZ then
        -- Wall is too tall to mount — just drop gracefully
        cleanupWallState()
        Helpers.resetCameraRoll()
        Helpers.playSound("lcm_wallrun_out")
        return
    end

    Helpers.playSound("ono_v_effort_short")

    -- Find landing spot: 0.8m past the wall at ledge height, raycast down
    local landX = pos.x - wallNormal.x * 0.8
    local landY = pos.y - wallNormal.y * 0.8
    local overOrigin = Vector4.new(landX, landY, ledgeZ + 2.0, 0)
    local hitGround, groundPos = Helpers.raycast(
        overOrigin, Vector4.new(0, 0, -1, 0), 5.0
    )
    -- Land at ground + 0.1 (player Z is at feet, need clearance for model)
    local landZ = hitGround and (groundPos.z + 0.1) or ledgeZ

    -- Arc height scales with distance to ledge: small hop for nearby, taller for far
    local climbDist = math.max(0, ledgeZ - pos.z)
    local clearance = 0.15 + climbDist * 0.05
    local peakZ = math.max(ledgeZ + clearance, landZ + clearance)

    ledgeMount.startPos = Vector4.new(pos.x, pos.y, pos.z, 1)
    ledgeMount.landPos  = Vector4.new(landX, landY, landZ, 1)
    ledgeMount.peakZ    = peakZ
    ledgeMount.timer       = 0
    ledgeMount.duration    = 0.6
    ledgeMount.startTilt   = camera.tilt

    -- Precompute Z quadratic through: z(0)=startZ, z(0.5)=peakZ, z(1)=landZ
    local sZ, pZ, lZ = pos.z, peakZ, landZ
    ledgeMount.zA = 2*lZ + 2*sZ - 4*pZ
    ledgeMount.zB = 4*pZ - 3*sZ - lZ
    ledgeMount.zC = sZ

    -- Compute target yaw: rotate camera to face the wall
    ledgeMount.startYaw = wallState.player:GetWorldYaw()
    local fwd = Game.GetCameraSystem():GetActiveCameraForward()
    local fwdFlat = Vector4.Normalize(Vector4.new(fwd.x, fwd.y, 0, 0))
    local wallFace = Vector4.Normalize(Vector4.new(-wallNormal.x, -wallNormal.y, 0, 0))
    local dot   = fwdFlat.x * wallFace.x + fwdFlat.y * wallFace.y
    local cross = fwdFlat.x * wallFace.y - fwdFlat.y * wallFace.x
    ledgeMount.targetYaw = ledgeMount.startYaw + math.deg(math.atan2(cross, dot))

    -- Clear wall run state (manually instead of cleanupWallState to preserve LEDGE_MOUNTING phase)
    wallState.wallSide     = nil
    wallState.wallNormal   = nil
    wallState.wallRunDir   = nil
    wallState.kickDirection = nil
    wallState.aimHoldZ     = nil
    wallState.timer        = 0
    wallState.wallLostTimer = nil
    wallState.phase        = "LEDGE_MOUNTING"
    camera.targetTilt = 0
end

enterWallClimb = function(wallNormal, isChain)
    resetFallState()
    wallState.phase       = "WALL_CLIMBING"
    setClimbBlock(true)
    wallState.isClimbBlocked = true
    wallState.wallNormal  = wallNormal
    wallState.wallSide    = nil
    wallState.wallRunDir  = nil
    wallState.climbTimer  = 0
    -- Only reset shared timer if not carrying over from a chain
    if wallState.timer <= 0 then
        wallState.timer = cfg.wallClimbDuration
    end
    wallState.wallClimbUsedThisJump = true
    wallState.entryZ      = wallState.player:GetWorldPosition().z
    wallState.targetZ     = wallState.entryZ
    wallState.footstepTimer = 0
    camera.targetTilt = 0
    camera.rollBlendProgress = 0
    camera.tilt       = 0
    camera.trackedYaw   = wallState.player:GetWorldYaw()
    camera.pendingMouseDeltaX = 0

    if not isChain then Helpers.playSound("lcm_wallrun_in") end
    Kerenzikov.awardShinobiXP(isChain and 7.0 or 5.0)
end

local function wallKick()
    local wn = wallState.wallNormal or Vector4.new(0, 0, 0, 0)
    wallState.lastKickWallNormal = wallState.wallNormal
    cleanupWallState()
    Helpers.resetCameraRoll()
    local arcBoost = cfg.wallKickForce * KICK_ARC_RATIO
    Helpers.queueWallKick(Vector4.new(wn.x * cfg.wallKickForce, wn.y * cfg.wallKickForce, arcBoost, 0))
    Helpers.stopSound("lcm_player_double_jump")
    Helpers.playSound("lcm_player_double_jump")
    Kerenzikov.awardShinobiXP(wallState.chainCount > 0 and 15.0 or 10.0)
end

beginWallJump = function(skipSound)
    drainStamina(STAMINA_WALL_KICK)
    wallState.suppressStaminaRegen = cfg.drainStamina
    Kerenzikov.pause()
    wallState.phaseTimer       = 0
    wallState.aimDuration    = 0.35
    wallState.aimStartTilt   = camera.tilt
    wallState.lastKickWallNormal  = wallState.wallNormal
    wallState.phase         = "WALL_JUMP_AIM"
    if not skipSound then Helpers.playSound("w_gun_pistol_tech_kenshin_charge") end
    input.jumpJustPressed = false
    wallState.wallSide      = nil
    wallState.wallNormal    = nil
    wallState.wallRunDir    = nil
    wallState.timer         = 0
    wallState.cooldown      = 0
end

beginReverseHang = function()
    drainStamina(STAMINA_WALL_KICK)
    Helpers.playSound("w_gun_pistol_tech_kenshin_charge")
    wallState.wallClimbUsedThisJump = false
    local pos = wallState.player:GetWorldPosition()
    wallState.reverseHangTimer    = 0
    wallState.reverseHangYawStart = camera.trackedYaw
    wallState.reverseHangYawEnd   = math.deg(math.atan2(-wallState.wallNormal.x, wallState.wallNormal.y))
    wallState.reverseHangPos      = Vector4.new(pos.x, pos.y, pos.z, 1)
    wallState.reverseHangNormal   = Vector4.new(wallState.wallNormal.x, wallState.wallNormal.y, wallState.wallNormal.z, wallState.wallNormal.w)
    wallState.phase = "REVERSE_WALL_HANG"
end

beginExitPush = function(kickDir, kickSpeed)
    wallState.kickDirection = kickDir
    wallState.phaseTimer = 0
    wallState.aimStartTilt = 0
    wallState.exitPushSpeed = kickSpeed
    wallState.exitPushUpSpeed = 0.0
    wallState.exitPushDuration = 0.5
    wallState.exitPushVelocityZ = wallState.player:GetVelocity().z
    wallState.exitPushGrounded = false
    wallState.exitPushLandTime = 0
    wallState.phase = "EXIT_PUSH"
end

---------------------------------------------------------------------------
-- Phase handler functions
---------------------------------------------------------------------------

local function updateIdle(dt, airborne, dashCancel, LynxPaw)
    -- Fire deferred impulse kick (queued previous frame so locomotion state can settle)
    if wallState.pendingKickImpulse then
        local imp = PSMImpulse.new()
        imp.id = "impulse"
        imp.impulse = wallState.pendingKickImpulse
        wallState.player:QueueEvent(imp)
        wallState.pendingKickImpulse = nil
    end

    -- Post-kick chain detection: scan for walls during the impulse arc
    if wallState.chainScanTimer then
        wallState.chainScanTimer = wallState.chainScanTimer + dt

        if wallState.chainScanTimer > 0.1 and wallState.chainScanTimer < CHAIN_SCAN_WINDOW
           and airborne and (cfg.unlimitedWallChains or wallState.chainCount < cfg.maxWallChains) then
            -- Side walls → wall run
            local side, sideRayDir, sideDist, sideHitPos = WallDetect.detectWall()
            if side and sideDist < cfg.wallDetectDistance then
                local wallN = WallDetect.calculateWallNormal(Helpers.getPlayerHipPosition(), sideHitPos)
                if not isSameWall(wallN) then
                    wallState.chainScanTimer = nil
                    wallState.chainScanDirection = nil
                    wallState.chainCount = wallState.chainCount + 1
                    wallState.wallRunUsedThisJump = false
                    enterWallRun(side, sideRayDir, wallN, true)
                    wallState.timer = math.min(wallState.timer + cfg.chainBonusDuration, cfg.wallRunDuration)
                    return
                end
            end
            -- Forward wall check via shared classification
            if tryChainWall(nil) then
                wallState.chainScanTimer = nil
                wallState.chainScanDirection = nil
                return
            end
        end

        if wallState.chainScanTimer >= CHAIN_SCAN_WINDOW then
            wallState.chainScanTimer = nil
            wallState.chainScanDirection = nil
        end
    end

    -- Clear climb block once when returning to idle
    if wallState.isClimbBlocked then
        setClimbBlock(false)
        wallState.isClimbBlocked = false
    end

    -- Single-frame capsule reset after ledge mount
    if wallState.capsuleReset then
        StatusEffectHelper.RemoveStatusEffect(wallState.player,
            TweakDBID.new("GameplayRestriction.ForceCrouch"))
        wallState.capsuleReset = false
    end

    SafeLanding.updateUncrouch(dt)
    SafeLanding.updateCleanup(dt)
    SafeLanding.updateRollSound(dt)
    SafeLanding.updateRoll(dt)

    -- Suppress stamina regen after wall kick until landing
    if wallState.suppressStaminaRegen then
        if airborne then
            drainStamina(0.01)
        else
            wallState.suppressStaminaRegen = false
        end
    end

    -- Safety: always clear camera roll in IDLE
    if math.abs(camera.tilt) > 0.1 then
        camera.tilt = Helpers.lerpAngle(camera.tilt, 0, cfg.cameraLerpSpeed * 2, dt)
        Helpers.applyCameraRoll(camera.tilt)
    elseif math.abs(camera.tilt) > 0 then
        camera.tilt = 0
        Helpers.applyCameraRoll(0)
    end

    local vel = wallState.player:GetVelocity()
    if airborne
       and (not cfg.requireLynxPaws or LynxPaw.equipped)
       and (not cfg.requireSprint or input.pressingSprint)
       and (dashCancel or vel.z >= 0)
    then
        local action, side, rayDir, wallN, deg = WallDetect.qualifyWallAction(vel)
        if action and isSameWall(wallN) then
            Helpers.logDebug("[IDLE] rejected: same wall")
        elseif not hasEnoughStamina() then
            Helpers.logDebug("[IDLE] rejected: not enough stamina")
        elseif action == "climb" then
            Helpers.logDebug(string.format("[IDLE] => enterWallClimb deg=%.1f", deg))
            wallState.climbEntryDeg = deg
            enterWallClimb(wallN)
        elseif action == "run" then
            Helpers.logDebug(string.format("[IDLE] => enterWallRun side=%s", side))
            enterWallRun(side, rayDir, wallN)
        end
    end
end

local function updateWallRunning(dt, airborne, dashCancel, LynxPaw)
    Kerenzikov.updateADS()

    if input.pressingBack and input.jumpJustPressed and hasEnoughStamina() then
        beginReverseHang()
        return
    end

    if input.jumpJustPressed and hasEnoughStamina() then
        beginWallJump()
        return
    end

    -- Wall detection probes — all feed a shared grace timer
    local pos = wallState.player:GetWorldPosition()
    local rayDir = Vector4.new(-wallState.wallNormal.x, -wallState.wallNormal.y, 0, 0)
    local detectRange = cfg.wallDetectDistance * 1.5 + 0.15
    local wallLost = false
    local lostReason = nil

    -- 1. Wall still beside us? (hip ray with knee fallback)
    local hit, hitPos, dist = Helpers.raycastWithKneeFallback(pos, rayDir, detectRange)
    if not hit then
        wallLost = true
        lostReason = string.format("wall lost: rayDir=(%.2f,%.2f) range=%.2f", rayDir.x, rayDir.y, detectRange)
    end

    -- 2. Obstacle ahead?
    if not wallLost then
        local origin = Helpers.getPlayerHipPosition()
        local lookAhead = wallState.wallRunEntrySpeed * 0.3
        local hitAhead = Helpers.raycast(origin, wallState.wallRunDir, lookAhead)
        if hitAhead then
            wallLost = true
            lostReason = string.format("obstacle ahead: dir=(%.2f,%.2f) lookAhead=%.2f",
                wallState.wallRunDir.x, wallState.wallRunDir.y, lookAhead)
        end
    end

    -- 3. Wall ending ahead? (hip + knee fallback at offset position)
    if not wallLost then
        local endLook = wallState.wallRunEntrySpeed * 0.1
        local aheadPos = Vector4.new(
            pos.x + wallState.wallRunDir.x * endLook,
            pos.y + wallState.wallRunDir.y * endLook,
            pos.z, 1
        )
        local wallAhead = Helpers.raycastWithKneeFallback(aheadPos, rayDir, detectRange)
        if not wallAhead then
            wallLost = true
            lostReason = string.format("wall ending: endLook=%.2f", endLook)
        end
    end

    -- 4. Curve check — normal deviation from entry (only when wall was found)
    if not wallLost then
        local newNormal = WallDetect.calculateWallNormal(Helpers.getPlayerHipPosition(), hitPos)
        local normalDot = wallState.wallRunEntryNormal.x * newNormal.x + wallState.wallRunEntryNormal.y * newNormal.y
        if normalDot < 0.95 then
            Helpers.logDebug(string.format("[WR_EXIT] curve: normalDot=%.3f entryN=(%.2f,%.2f) newN=(%.2f,%.2f)",
                normalDot, wallState.wallRunEntryNormal.x, wallState.wallRunEntryNormal.y, newNormal.x, newNormal.y))
            exitWallRun()
            return
        end
        wallState.wallNormal = newNormal
    end

    -- Shared grace timer — ride through brief gaps, exit on sustained loss
    if wallLost then
        wallState.wallLostTimer = (wallState.wallLostTimer or 0) + dt
        if wallState.wallLostTimer >= WALL_RUN_GRACE_DURATION then
            Helpers.logDebug(string.format("[WR_EXIT] %s grace=%.3f", lostReason, wallState.wallLostTimer))
            exitWallRun()
            if lostReason:find("wall ending") then
                local psmEvent = PSMPostponedParameterBool.new()
                psmEvent.id = CName.new("locomotionForceSprintToggle")
                psmEvent.value = true
                wallState.player:QueueEvent(psmEvent)
            end
            return
        end
    else
        wallState.wallLostTimer = nil
    end

    -- Kerenzikov: slow time progression for comfortable aiming
    local kMult = wallState.kerenzikovActive and Kerenzikov.speedMultiplier or 1.0

    -- Independent elapsed tracker for speed decay (always ticks, even with unlimited/kerenzikov)
    wallState.wallRunElapsed = (wallState.wallRunElapsed or 0) + dt

    -- Update target Z: rise at start, gradually sink over duration
    -- Freeze vertical arc during grace (gaps) to prevent height drift
    local elapsed  = cfg.wallRunDuration - wallState.timer
    local fraction = elapsed / cfg.wallRunDuration
    local vertSpeed = wallLost and 0 or (cfg.riseSpeed * (1.0 - fraction * cfg.sinkRate) * kMult)

    -- Vertical clamping: probe wall extent and ceiling before applying vertSpeed
    if vertSpeed ~= 0 then
        local probeZ = (vertSpeed > 0)
            and (wallState.targetZ + WALL_RUN_VERT_PROBE_OFFSET)
            or  (wallState.targetZ - WALL_RUN_VERT_PROBE_OFFSET)
        local probeOrigin = Vector4.new(pos.x, pos.y, probeZ, 0)
        local wallAtProbe = Helpers.raycast(probeOrigin, rayDir, detectRange)
        if not wallAtProbe then
            vertSpeed = 0  -- wall doesn't exist at projected height, stay level
        end
    end
    if vertSpeed > 0 and wallState.targetZ >= wallState.entryZ + 0.75 then
        vertSpeed = 0  -- cap rise at 0.75m above entry height
    end
    if vertSpeed > 0 then
        -- Ceiling probe: prevent rising into overhead geometry
        local headOrigin = Vector4.new(pos.x, pos.y, pos.z + 1.8, 0)
        local upDir = Vector4.new(0, 0, 1, 0)
        local hitCeiling = Helpers.raycast(headOrigin, upDir, 0.5)
        if hitCeiling then
            vertSpeed = 0  -- ceiling too close, stay level
        end
    elseif vertSpeed < 0 then
        -- Floor probe: prevent sinking into the ground
        local feetOrigin = Vector4.new(pos.x, pos.y, wallState.targetZ + 0.1, 0)
        local downDir = Vector4.new(0, 0, -1, 0)
        local hitGround, groundPos, groundDist = Helpers.raycast(feetOrigin, downDir, 0.5)
        if hitGround and groundDist < 0.3 then
            vertSpeed = 0
            wallState.targetZ = math.max(wallState.targetZ, groundPos.z + 0.05)
        end
    end

    wallState.targetZ = wallState.targetZ + vertSpeed * dt

    -- Lateral movement along wall — entry speed decays toward minimum over time
    local decayFrac = math.min(wallState.wallRunElapsed / WALL_RUN_SPEED_DECAY, 1.0)
    local runSpeed = wallState.wallRunEntrySpeed + (WALL_RUN_MIN_SPEED - wallState.wallRunEntrySpeed) * decayFrac
    if wallState.kerenzikovActive then runSpeed = Kerenzikov.wallRunSpeed end
    local moveX = wallState.wallRunDir.x * runSpeed * dt
    local moveY = wallState.wallRunDir.y * runSpeed * dt

    -- Position: always coast (no wall snap), use wall hit only for distance enforcement
    local wallDist = cfg.targetWallDist + 0.15
    local newPos
    if hit then
        newPos = Vector4.new(
            hitPos.x + wallState.wallNormal.x * wallDist + moveX,
            hitPos.y + wallState.wallNormal.y * wallDist + moveY,
            wallState.targetZ,
            1
        )
    else
        newPos = Vector4.new(
            pos.x + moveX,
            pos.y + moveY,
            wallState.targetZ,
            1
        )
    end

    camera.trackedYaw = camera.trackedYaw - Helpers.consumeAimYaw(dt)

    Game.GetTeleportationFacility():Teleport(
        wallState.player,
        newPos,
        EulerAngles.new(0, 0, camera.trackedYaw)
    )

    -- Smooth roll via camera component
    camera.rollBlendProgress = math.min(1.0, camera.rollBlendProgress + cfg.cameraLerpSpeed * dt)
    local rt = Helpers.smoothstep(camera.rollBlendProgress)
    camera.tilt = camera.targetTilt * rt
    Helpers.applyCameraRoll(camera.tilt)

    Helpers.playFootsteps(dt, kMult)

    -- Stamina drain (continuous, scaled by Kerenzikov) — out of stamina forces slide
    drainStamina(STAMINA_WALL_RUN_PER_SEC * dt * kMult)
    if cfg.drainStamina and getStamina() <= 0 then
        transitionToSlide()
        return
    end

    -- Timer (paused during kerenzikov, otherwise runs normally)
    if not cfg.unlimitedWallRun and not wallState.kerenzikovActive then
        wallState.timer = wallState.timer - dt
        if wallState.timer <= 0 then
            -- Try ledge mount first when wall run expires near a top
            if Helpers.findLedgeTop(pos, wallState.wallNormal) then
                beginLedgeMount(wallState.wallNormal)
                return
            end
            if not cfg.unlimitedWallSlide and wallState.slideBudget <= 0 then
                exitWallRun()
                return
            end
            transitionToSlide()
            return
        end
    end
end

local function updateWallClimbing(dt, airborne, dashCancel, LynxPaw)
    if input.pressingBack and input.jumpJustPressed and hasEnoughStamina() then
        beginReverseHang()
        return
    end

    if input.jumpJustPressed and hasEnoughStamina() then
        beginWallJump()
        return
    end

    -- Check for ceiling above
    local pos = wallState.player:GetWorldPosition()
    local headOrigin = Vector4.new(pos.x, pos.y, pos.z + 1.8, 0)
    local upDir = Vector4.new(0, 0, 1, 0)
    local hitCeiling, _, ceilDist = Helpers.raycast(headOrigin, upDir, 0.5)

    if hitCeiling then
        wallState.phase = "IDLE"
        setClimbBlock(false)
        wallState.wallNormal = nil
        wallState.snapTimer = 4.0
        Helpers.playSound("lcm_wallrun_out")
        return
    end

    Helpers.playFootsteps(dt)

    -- Stamina drain (continuous) — out of stamina forces slide
    drainStamina(STAMINA_WALL_CLIMB_PER_SEC * dt)
    if cfg.drainStamina and getStamina() <= 0 then
        transitionToSlide()
        return
    end

    -- Shared duration timer
    if not cfg.unlimitedWallClimb then
        wallState.timer = wallState.timer - dt
        if wallState.timer <= 0 and not wallState.climbPeakHoldTimer then
            -- If a ledge is within reach, mount immediately — no pause
            if Helpers.findLedgeTop(pos, wallState.wallNormal) then
                beginLedgeMount(wallState.wallNormal)
                return
            end
            -- No ledge — enter peak hold before transitioning to slide
            wallState.climbPeakHoldTimer = PEAK_HOLD_DURATION
        end
    end

    -- Peak hold (only entered when no ledge was found above)
    if wallState.climbPeakHoldTimer then
        wallState.climbPeakHoldTimer = wallState.climbPeakHoldTimer - dt
        if wallState.climbPeakHoldTimer <= 0 then
            wallState.climbPeakHoldTimer = nil
            if not cfg.unlimitedWallSlide and wallState.slideBudget <= 0 then
                exitWallRun()
                return
            end
            transitionToSlide()
            return
        end
    else
        local vertSpeed = cfg.riseSpeed * 3.0
        wallState.targetZ = wallState.targetZ + vertSpeed * dt
    end

    -- Ground check
    local feetOrigin = Vector4.new(pos.x, pos.y, wallState.targetZ + 0.1, 0)
    local downDir = Vector4.new(0, 0, -1, 0)
    local hitGround, groundPos, groundDist = Helpers.raycast(feetOrigin, downDir, 0.3)
    if hitGround and groundDist < 0.2 then
        wallState.targetZ = math.max(wallState.targetZ, groundPos.z + 0.05)
    end

    -- Try to stick to wall
    local rayDir = Vector4.new(-wallState.wallNormal.x, -wallState.wallNormal.y, 0, 0)
    local hitWall, hitPos, dist = Helpers.raycastWithKneeFallback(pos, rayDir, cfg.wallDetectDistance * 1.5)

    local newPos
    if hitWall then
        wallState.wallNormal = WallDetect.calculateWallNormal(Helpers.getPlayerHipPosition(), hitPos)
        wallState.wallLostTimer = nil
        newPos = Vector4.new(
            hitPos.x + wallState.wallNormal.x * cfg.targetWallDist,
            hitPos.y + wallState.wallNormal.y * cfg.targetWallDist,
            wallState.targetZ,
            1
        )
    else
        beginLedgeMount(wallState.wallNormal)
        return
    end

    camera.trackedYaw = camera.trackedYaw - Helpers.consumeAimYaw(dt)

    Game.GetTeleportationFacility():Teleport(
        wallState.player, newPos,
        EulerAngles.new(0, 0, camera.trackedYaw)
    )
end

local function updateWallSliding(dt, airborne, dashCancel, LynxPaw)
    if input.pressingBack and input.jumpJustPressed and hasEnoughStamina() then
        Helpers.stopSound("lcm_fs_additional_tiles_slide")
        beginReverseHang()
        return
    end

    if input.jumpJustPressed and hasEnoughStamina() then
        Helpers.stopSound("lcm_fs_additional_tiles_slide")
        beginWallJump()
        return
    end

    local pos = wallState.player:GetWorldPosition()

    local function slideExit()
        Helpers.stopSound("lcm_fs_additional_tiles_slide")
        exitWallRun()
    end

    -- Trickle drain to suppress regen during slide
    if cfg.drainStamina then drainStamina(0.01) end

    -- Slide duration timer
    if not cfg.unlimitedWallSlide then
        wallState.timer = wallState.timer - dt
        wallState.slideBudget = wallState.slideBudget - dt
    end
    if not cfg.unlimitedWallSlide and wallState.timer <= 0 then
        slideExit()
        return
    end

    -- Slow descent
    local slideSpeed = cfg.riseSpeed * 0.5
    wallState.targetZ = wallState.targetZ - slideSpeed * dt

    -- Ground proximity
    local feetOrigin = Vector4.new(pos.x, pos.y, wallState.targetZ + 0.1, 0)
    local downDir = Vector4.new(0, 0, -1, 0)
    local hitGround, groundPos, groundDist = Helpers.raycast(feetOrigin, downDir, 0.5)
    if hitGround and groundDist < 0.4 then
        slideExit()
        return
    end

    -- Wall adherence
    local rayDir = Vector4.new(-wallState.wallNormal.x, -wallState.wallNormal.y, 0, 0)
    local hitWall, hitPos, dist = Helpers.raycastWithKneeFallback(pos, rayDir, cfg.wallDetectDistance * 1.5)

    if not hitWall then
        slideExit()
        return
    end

    wallState.wallNormal = WallDetect.calculateWallNormal(Helpers.getPlayerHipPosition(), hitPos)
    local newPos = Vector4.new(
        hitPos.x + wallState.wallNormal.x * cfg.targetWallDist,
        hitPos.y + wallState.wallNormal.y * cfg.targetWallDist,
        wallState.targetZ,
        1
    )

    camera.trackedYaw = camera.trackedYaw - Helpers.consumeAimYaw(dt)

    Game.GetTeleportationFacility():Teleport(
        wallState.player, newPos,
        EulerAngles.new(0, 0, camera.trackedYaw)
    )
end

local function updateReverseWallHang(dt, airborne, dashCancel, LynxPaw)
    wallState.reverseHangTimer = wallState.reverseHangTimer + dt
    local t = math.min(wallState.reverseHangTimer / wallState.reverseHangDuration, 1.0)

    if wallState.reverseHangDone then
        Game.GetTeleportationFacility():Teleport(
            wallState.player, wallState.reverseHangPos,
            EulerAngles.new(0, 0, camera.trackedYaw))
        wallState.aimHoldX = wallState.reverseHangPos.x
        wallState.aimHoldY = wallState.reverseHangPos.y
        wallState.aimHoldZ = wallState.reverseHangPos.z
        Helpers.resetCameraRoll()
        wallState.wallNormal = wallState.reverseHangNormal
        beginWallJump(true)
        wallState.aimDuration = cfg.wallKickAimHold + 0.25
        wallState.reverseHangTimer = nil
        wallState.reverseHangDone  = false
        return
    end

    local eased = Helpers.smoothstep(t)
    camera.trackedYaw = Helpers.angleLerp(wallState.reverseHangYawStart, wallState.reverseHangYawEnd, eased)

    -- Pitch scoop: up in the middle, level at start/end
    local pitch = RHANG_SCOOP_DEG * math.sin(math.pi * t)
    -- Tilt into the turn direction, same magnitude as wall-run head tilt
    local yawDiff = ((wallState.reverseHangYawEnd - wallState.reverseHangYawStart + 180) % 360) - 180
    local tiltSign = yawDiff > 0 and 1 or -1
    local roll = tiltSign * (cfg.cameraTilt * 0.5) * math.sin(math.pi * t)
    local camComp = wallState.player:GetFPPCameraComponent()
    if camComp then
        local quat = EulerAngles.ToQuat(EulerAngles.new(-roll, pitch, 0))
        camComp:SetLocalOrientation(quat)
    end

    Game.GetTeleportationFacility():Teleport(
        wallState.player, wallState.reverseHangPos,
        EulerAngles.new(0, 0, camera.trackedYaw))

    if t >= 1.0 then
        wallState.reverseHangDone = true
    end
end

local function updateWallJumpAim(dt, airborne, dashCancel, LynxPaw)
    if cfg.drainStamina then drainStamina(0.01) end
    wallState.phaseTimer = wallState.phaseTimer + dt
    local aimDuration = wallState.aimDuration or cfg.wallKickAimHold

    local pos = wallState.player:GetWorldPosition()
    if not wallState.aimHoldZ then
        wallState.aimHoldZ = pos.z
        wallState.aimHoldX = pos.x
        wallState.aimHoldY = pos.y
    end
    if math.abs(pos.z - wallState.aimHoldZ) > 0.01
       or math.abs(pos.x - wallState.aimHoldX) > 0.01
       or math.abs(pos.y - wallState.aimHoldY) > 0.01 then
        Game.GetTeleportationFacility():Teleport(
            wallState.player,
            Vector4.new(wallState.aimHoldX, wallState.aimHoldY, wallState.aimHoldZ, 1),
            EulerAngles.new(0, 0, wallState.player:GetWorldYaw())
        )
    end

    local t = aimDuration > 0 and math.min(1.0, wallState.phaseTimer / aimDuration) or 1.0
    camera.tilt = (wallState.aimStartTilt or 0) * (1.0 - t)
    Helpers.applyCameraRoll(camera.tilt)

    if (not cfg.unlimitedHangtime and wallState.phaseTimer >= aimDuration) or (input.jumpJustPressed and wallState.phaseTimer > 0.1) then
        local fwd = Game.GetCameraSystem():GetActiveCameraForward()
        Helpers.resetCameraRoll()

        local wn = wallState.lastKickWallNormal
        if wn and not wallState.wallClimbUsedThisJump then
            local fwdFlat = Vector4.Normalize(Vector4.new(fwd.x, fwd.y, 0, 0))
            local lookDot = fwdFlat.x * wn.x + fwdFlat.y * wn.y
            local lookDeg = math.deg(math.acos(math.max(-1, math.min(1, -lookDot))))
            if lookDot < 0 and lookDeg <= cfg.wallRunEntryAngle then
                Kerenzikov.deactivate()
                wallState.aimHoldZ = nil
                wallState.lastKickWallNormal = nil
                wallState.climbEntryDeg = lookDeg
                enterWallClimb(wn)
                return
            end
        end

        -- Impulse-based kick
        local force = cfg.wallKickForce
        local clampedZ = math.max(-0.3, math.min(0.3, fwd.z))
        local arcBoost = force * AIM_KICK_ARC_RATIO
        wallState.kickDirection = nil
        wallState.aimHoldZ = nil
        wallState.phase = "IDLE"
        Kerenzikov.deactivate()
        Helpers.queueWallKick(Vector4.new(fwd.x * force, fwd.y * force, clampedZ * force + arcBoost, 0))
        Helpers.stopSound("lcm_player_double_jump")
        Helpers.playSound("lcm_player_double_jump")
    end
end

local function updateWallJumping(dt, airborne, dashCancel, LynxPaw)
    -- Kerenzikov may carry over from wall run — let it ride but don't activate new
    local kMult = wallState.kerenzikovActive and Kerenzikov.speedMultiplier or 1.0
    local dashDuration = DASH_DURATION

    local airKerenMult = 1.0
    if wallState.kerenzikovActive and Kerenzikov.hasAirKerenzikovPerk() then
        local kickT = wallState.phaseTimer / dashDuration
        if kickT >= 0.5 then
            airKerenMult = 0.1
        elseif kickT >= 0.4 then
            local ramp = (kickT - 0.4) / 0.1
            airKerenMult = 1.0 - ramp * 0.9
        end
    end

    wallState.phaseTimer = wallState.phaseTimer + dt * kMult * airKerenMult

    if wallState.phaseTimer < dashDuration and wallState.kickDirection then
        local pos = wallState.player:GetWorldPosition()
        local kickT = wallState.phaseTimer / dashDuration

        local moveX = wallState.kickDirection.x * kMult * airKerenMult * dt
        local moveY = wallState.kickDirection.y * kMult * airKerenMult * dt
        local arcUp = ARC_HEIGHT
        local arcZ = arcUp * (1.0 - 1.5 * kickT) * kMult * airKerenMult * dt
        local moveZ = wallState.kickDirection.z * kMult * airKerenMult * dt + arcZ

        local origin = Vector4.new(pos.x, pos.y, pos.z + 1.0, 0)
        local moveDir = Vector4.Normalize(Vector4.new(moveX, moveY, moveZ, 0))
        local moveDist = math.sqrt(moveX * moveX + moveY * moveY + moveZ * moveZ)
        local hit, hitPos, hitDist = Helpers.raycast(origin, moveDir, moveDist + 0.5)

        if hit and hitDist < moveDist + 0.3 then
            local kickSpeed = Vector4.Length2D(Vector4.new(wallState.kickDirection.x, wallState.kickDirection.y, 0, 0)) * kMult
            local kickDir = Vector4.Normalize(Vector4.new(wallState.kickDirection.x, wallState.kickDirection.y, 0, 0))
            wallState.kickDirection = nil
            if not tryChainWall(kickDir) then
                beginExitPush(kickDir, kickSpeed)
            end
        else
            camera.trackedYaw = camera.trackedYaw - Helpers.consumeAimYaw(dt)

            local newPos = Vector4.new(
                pos.x + moveX, pos.y + moveY, pos.z + moveZ, pos.w
            )
            Game.GetTeleportationFacility():Teleport(
                wallState.player, newPos,
                EulerAngles.new(0, 0, camera.trackedYaw)
            )

            if wallState.phaseTimer > 0.1 and tryChainWall(nil) then
                wallState.kickDirection = nil
            end
        end
    else
        local kickSpeed = wallState.kickDirection and Vector4.Length2D(Vector4.new(wallState.kickDirection.x, wallState.kickDirection.y, 0, 0)) * kMult or 0
        local kickDir = wallState.kickDirection and Vector4.Normalize(Vector4.new(wallState.kickDirection.x, wallState.kickDirection.y, 0, 0)) or nil
        wallState.kickDirection = nil
        if not tryChainWall(kickDir) then
            beginExitPush(kickDir, kickSpeed)
        end
    end
end

local function updateAirHover(dt, airborne, dashCancel, LynxPaw)
    if cfg.triggerKerenzikov and Kerenzikov.hasKerenzikov() then
        if Kerenzikov.isAimingDownSights() then
            if not wallState.kerenzikovActive then Kerenzikov.activate() end
        else
            Kerenzikov.deactivate()
            wallState.phase = "IDLE"
        end
    end

    if wallState.phase == "AIR_HOVER" then
        wallState.hoverTimer = wallState.hoverTimer + dt
        local hoverDuration = HOVER_DURATION
        local pos = wallState.player:GetWorldPosition()
        if math.abs(pos.z - wallState.hoverZ) > 0.01
           or math.abs(pos.x - wallState.hoverX) > 0.01
           or math.abs(pos.y - wallState.hoverY) > 0.01 then
            Game.GetTeleportationFacility():Teleport(
                wallState.player,
                Vector4.new(wallState.hoverX, wallState.hoverY, wallState.hoverZ, 1),
                EulerAngles.new(0, 0, wallState.player:GetWorldYaw())
            )
        end

        local buffGone = not Game.GetStatusEffectSystem():HasStatusEffect(
            wallState.player:GetEntityID(), TweakDBID.new("BaseStatusEffect.KerenzikovPlayerBuff"))
        if wallState.hoverTimer >= hoverDuration or buffGone then
            Kerenzikov.deactivate()
            wallState.phase = "IDLE"
        end
    end
end

local function updateLedgeMounting(dt, airborne, dashCancel, LynxPaw)
    ledgeMount.timer = ledgeMount.timer + dt
    local t = math.min(1.0, ledgeMount.timer / ledgeMount.duration)
    local st = Helpers.smoothstep(t)

    local x = ledgeMount.startPos.x + (ledgeMount.landPos.x - ledgeMount.startPos.x) * st
    local y = ledgeMount.startPos.y + (ledgeMount.landPos.y - ledgeMount.startPos.y) * st
    local z = ledgeMount.zA * t * t + ledgeMount.zB * t + ledgeMount.zC

    local yawDiff = ledgeMount.targetYaw - ledgeMount.startYaw
    local yaw = ledgeMount.startYaw + yawDiff * st

    Game.GetTeleportationFacility():Teleport(
        wallState.player,
        Vector4.new(x, y, z, 1),
        EulerAngles.new(0, 0, yaw)
    )

    camera.tilt = (ledgeMount.startTilt or 0) * (1.0 - st)
    Helpers.applyCameraRoll(camera.tilt)

    if t >= 1.0 then
        Helpers.resetCameraRoll()
        StatusEffectHelper.ApplyStatusEffect(wallState.player,
            TweakDBID.new("GameplayRestriction.ForceCrouch"))
        wallState.capsuleReset = true
        wallState.phase   = "IDLE"
        wallState.cooldown = 0
    end
end

local function updateExitPush(dt, airborne, dashCancel, LynxPaw)
    -- Kerenzikov may carry over from wall run — let it ride but don't activate new
    local kMult = wallState.kerenzikovActive and Kerenzikov.speedMultiplier or 1.0
    wallState.phaseTimer = wallState.phaseTimer + dt * kMult
    local dur = wallState.exitPushDuration or 0.3
    local speed = wallState.exitPushSpeed or 3.0
    local gravity = 9.8
    local maxTime = 5.0

    if wallState.phaseTimer < maxTime and wallState.kickDirection then
        local t = math.min(1.0, wallState.phaseTimer / dur)
        local grounded = wallState.exitPushGrounded or false
        local landTime = wallState.exitPushLandTime or 0
        local landFadeDur = 0.4

        camera.tilt = (wallState.aimStartTilt or 0) * (1.0 - t)
        Helpers.applyCameraRoll(camera.tilt)

        camera.trackedYaw = camera.trackedYaw - Helpers.consumeAimYaw(dt)

        local hSpeed = speed
        if grounded then
            local landElapsed = wallState.phaseTimer - landTime
            local landFade = 1.0 - math.min(1.0, landElapsed / landFadeDur)
            hSpeed = speed * landFade
            if landFade <= 0 then
                Kerenzikov.deactivate()
                Helpers.resetCameraRoll()
                wallState.phase = "IDLE"
                wallState.kickDirection = nil
                return
            end
        end

        local pos = wallState.player:GetWorldPosition()
        local moveX = wallState.kickDirection.x * hSpeed * kMult * dt
        local moveY = wallState.kickDirection.y * hSpeed * kMult * dt

        local moveZ = 0
        if not grounded then
            local velZ = (wallState.exitPushVelocityZ or 0) - gravity * wallState.phaseTimer
            moveZ = velZ * kMult * dt
        end

        local origin = Vector4.new(pos.x, pos.y, pos.z + 1.0, 0)
        local moveDir = Vector4.Normalize(Vector4.new(moveX, moveY, moveZ, 0))
        local moveDist = math.sqrt(moveX * moveX + moveY * moveY + moveZ * moveZ)
        local hitFwd, _, hitFwdDist = Helpers.raycast(origin, moveDir, moveDist + 0.5)
        if hitFwd and hitFwdDist < moveDist + 0.3 then
            local pushDir = Vector4.Normalize(Vector4.new(wallState.kickDirection.x, wallState.kickDirection.y, 0, 0))
            if tryChainWall(pushDir) then return end
            Kerenzikov.deactivate()
            Helpers.resetCameraRoll()
            wallState.phase = "IDLE"
            wallState.kickDirection = nil
            return
        end

        if not grounded then
            local feetOrigin = Vector4.new(pos.x + moveX, pos.y + moveY, pos.z + 0.1, 0)
            local hitGround, groundPos = Helpers.raycast(feetOrigin, Vector4.new(0, 0, -1, 0), math.abs(moveZ) + 0.3)
            if hitGround then
                wallState.exitPushGrounded = true
                wallState.exitPushLandTime = wallState.phaseTimer
                moveZ = groundPos.z - pos.z
            end
        end

        local newPos = Vector4.new(
            pos.x + moveX, pos.y + moveY, pos.z + moveZ, pos.w
        )
        Game.GetTeleportationFacility():Teleport(
            wallState.player, newPos,
            EulerAngles.new(0, 0, camera.trackedYaw)
        )

        if wallState.phaseTimer > 0.1 and tryChainWall(nil) then
            wallState.kickDirection = nil
            return
        end
    else
        Kerenzikov.deactivate()
        Helpers.resetCameraRoll()
        wallState.phase = "IDLE"
        wallState.kickDirection = nil
    end
end

---------------------------------------------------------------------------
-- Phase dispatch table
---------------------------------------------------------------------------
local phaseHandlers = {
    IDLE              = updateIdle,
    WALL_RUNNING      = updateWallRunning,
    WALL_CLIMBING     = updateWallClimbing,
    WALL_SLIDING      = updateWallSliding,
    REVERSE_WALL_HANG = updateReverseWallHang,
    WALL_JUMP_AIM     = updateWallJumpAim,
    WALL_JUMPING      = updateWallJumping,
    AIR_HOVER         = updateAirHover,
    LEDGE_MOUNTING    = updateLedgeMounting,
    EXIT_PUSH         = updateExitPush,
}

---------------------------------------------------------------------------
-- Per-frame update
---------------------------------------------------------------------------
local settingsSyncTimer = 0

--- Main per-frame update: syncs settings, detects walls, and drives the wall action state machine.
--- @param dt number Delta time in seconds.
--- @param syncSettings function Callback to synchronize mod settings from Redscript.
--- @param LynxPaw table The LynxPaw module for equipment checks.
function Phases.update(dt, syncSettings, LynxPaw)
    if not wallState.player then return end

    -- Periodically sync Mod Settings (every 2 seconds)
    settingsSyncTimer = settingsSyncTimer + dt
    if settingsSyncTimer > 2.0 then
        settingsSyncTimer = 0
        syncSettings()
        LynxPaw.equipped = LynxPaw.checkEquipped()
        if Kerenzikov.hasKerenzikov() then
            Kerenzikov.worldScale = Kerenzikov.getDilation()
            Kerenzikov.playerScale = Kerenzikov.getPlayerScale()
        end
    end

    -- Crouch speed modifier: apply/remove based on crouch + equipment state
    local isCrouching = Helpers.getDetailedLocomotionState()
        == EnumInt(gamePSMDetailedLocomotionStates.Crouch)
    LynxPaw.updateCrouchSpeed(isCrouching)

    -- Master toggle
    if not cfg.enabled then
        Kerenzikov.deactivate()
        if wallState.phase ~= "IDLE" then exitWallRun() end
        Helpers.resetCameraRoll()
        wallState.debugText = cfg.debugEnabled and "WallRun: DISABLED" or ""
        return
    end

    local airborne = Helpers.isAirborne() or Helpers.isAirDashing()

    -- Crouch buffer: runs independently of airborne state so it survives
    -- loco transitions. Only expires via its own timer or on consumption.
    local loco = Helpers.getDetailedLocomotionState()
    if input.crouchJustPressed and wallState.phase == "IDLE" and airborne and not wallState.crouchBufferUsed then
        wallState.crouchBuffered = true
        wallState.crouchBufferTimer = 0
        wallState.crouchBufferUsed = true  -- one shot per airborne period
        wallState.safeLandDebugText = nil
    end

    -- Crouch during wall phases: dismount immediately
    if input.crouchJustPressed and (wallState.phase == "WALL_RUNNING" or wallState.phase == "WALL_CLIMBING" or wallState.phase == "WALL_SLIDING" or wallState.phase == "WALL_JUMP_AIM") then
        Kerenzikov.deactivate()
        exitWallRun()
    end

    SafeLanding.updateCrouchBuffer(dt)
    SafeLanding.updateSafeLandFact()

    -- Safe landing intercept: when buffer is active and player touches down,
    -- trigger the roll if the fall was significant (>3m from peak).
    local fallDist = (wallState.airPeakZ or 0) - wallState.player:GetWorldPosition().z
    if wallState.crouchBuffered and wallState.phase == "IDLE" and not airborne and fallDist >= 3.0 then
        SafeLanding.triggerSafeRoll()
    elseif wallState.crouchBuffered and not airborne then
        SafeLanding.clearBuffer()
    end

    -- Track airborne time and peak height
    if airborne then
        wallState.airborneTime = wallState.airborneTime + dt
        local z = wallState.player:GetWorldPosition().z
        if not wallState.airPeakZ or z > wallState.airPeakZ then
            wallState.airPeakZ = z
        end
    else
        wallState.airborneTime = 0
        wallState.airPeakZ = nil
        wallState.wallRunUsedThisJump = false
        wallState.crouchBufferUsed = false
        wallState.wallClimbUsedThisJump = false
        wallState.lastKickWallNormal = nil
        wallState.chainCount = 0
        wallState.slideBudget = cfg.wallSlideDuration
        wallState.chainScanTimer = nil
        wallState.chainScanDirection = nil
        -- Don't cancel LEDGE_MOUNTING on ground contact (arc may touch ground)
        if wallState.phase == "WALL_RUNNING" then exitWallRun() end
        if wallState.phase == "EXIT_PUSH" and not wallState.exitPushGrounded then
            wallState.exitPushGrounded = true
            wallState.exitPushLandTime = wallState.phaseTimer
        end
        if wallState.phase == "WALL_JUMP_AIM"
           or wallState.phase == "WALL_JUMPING"
           or wallState.phase == "AIR_HOVER" then
            Kerenzikov.deactivate()
            wallState.phase = "IDLE"
            wallState.wallNormal = nil
            wallState.kickDirection = nil
            wallState.aimHoldZ = nil
        end
    end

    wallState.cooldown = wallState.cooldown + dt

    -- Track whether the player was airborne before a dash started
    local dashing = Helpers.isAirDashing()
    if not dashing then
        wallState.wasAirborneBeforeDash = airborne
    end
    local dashCancel = dashing and wallState.wasAirborneBeforeDash

    -- Cancel all mod logic if the player air dashes (but not if we took over the dash)
    if dashing and wallState.phase ~= "IDLE" and not wallState.isDashTakeover then
        local currentWallNormal = wallState.wallNormal
        yieldToGame()
        wallState.lastKickWallNormal = currentWallNormal or wallState.lastKickWallNormal
        wallState.cooldown = cfg.exitCooldown + 1
        wallState.wallRunUsedThisJump = false
        wallState.wallClimbUsedThisJump = false
        return
    end
    if not dashCancel then
        wallState.isDashTakeover = false
    end

    -- During air dash (even from IDLE), actively detect walls and take over mid-dash
    if dashCancel and wallState.phase == "IDLE" and airborne and (not cfg.requireLynxPaws or LynxPaw.equipped) and (not cfg.requireSprint or input.pressingSprint) then
        local vel = wallState.player:GetVelocity()
        local action, side, rayDir, wallN, deg = WallDetect.classifyWallAction(vel)

        if cfg.debugEnabled then
            wallState.debugText = wallState.debugText .. string.format(
                "\nDASH: action=%s deg=%.1f", tostring(action), deg or 0
            )
        end

        if action == "climb" and not isSameWall(wallN) then
            wallState.wallClimbUsedThisJump = false
            wallState.lastKickWallNormal = nil
            wallState.isDashTakeover = true
            wallState.climbEntryDeg = deg
            enterWallClimb(wallN)
            return
        elseif action == "run" and not isSameWall(wallN) then
            wallState.wallRunUsedThisJump = false
            wallState.lastKickWallNormal = nil
            wallState.isDashTakeover = true
            enterWallRun(side, rayDir, wallN)
            return
        end
    end

    -- Dispatch to current phase handler
    local handler = phaseHandlers[wallState.phase]
    if handler then handler(dt, airborne, dashCancel, LynxPaw) end

    -- Debug text (generated in debug.lua to keep phases.lua focused on logic)
    Debug.buildText(LynxPaw, airborne)
end

--- Begin a ledge mount sequence from the current wall climb position.
--- Exposed for init.lua's climb/vault observer hooks.
Phases.beginLedgeMount = beginLedgeMount

--- Yield control back to the game by resetting all wall action state and deactivating Kerenzikov.
--- Exposed for init.lua's climb/vault observer hooks.
Phases.yieldToGame = yieldToGame

return Phases
