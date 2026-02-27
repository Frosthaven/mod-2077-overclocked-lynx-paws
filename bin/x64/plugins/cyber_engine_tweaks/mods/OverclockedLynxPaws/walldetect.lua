local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local input = require("input")
local Helpers = require("helpers")

local WallDetect = {}

--- Calculate the along-wall movement direction, oriented to match the player's camera facing.
--- @param wallNormal Vector4 The wall surface normal (XY plane).
--- @return Vector4 The normalized horizontal direction parallel to the wall.
function WallDetect.calculateWallRunDirection(wallNormal)
    local dir = Vector4.new(-wallNormal.y, wallNormal.x, 0, 0)
    local fwd = Game.GetCameraSystem():GetActiveCameraForward()
    if (dir.x * fwd.x + dir.y * fwd.y) < 0 then
        dir = Vector4.new(-dir.x, -dir.y, 0, 0)
    end
    return dir
end

--- Compute the true wall surface normal using lateral offset raycasts from the hit point.
--- @param origin Vector4 The ray origin position.
--- @param hitPos Vector4 The ray hit position on the wall surface.
--- @return Vector4 The normalized wall surface normal pointing toward the player (XY plane).
function WallDetect.calculateWallNormal(origin, hitPos)
    -- Compute true wall surface normal using lateral offset raycasts
    local toWall = Vector4.Normalize(Vector4.new(hitPos.x - origin.x, hitPos.y - origin.y, 0, 0))
    local lateral = Vector4.new(-toWall.y, toWall.x, 0, 0)
    local offset = 0.15
    local dist = Vector4.Length(Vector4.new(hitPos.x - origin.x, hitPos.y - origin.y, 0, 0)) + 0.5
    local pL = Vector4.new(origin.x + lateral.x * offset, origin.y + lateral.y * offset, origin.z, 0)
    local pR = Vector4.new(origin.x - lateral.x * offset, origin.y - lateral.y * offset, origin.z, 0)
    local hitL, hitPosL = Helpers.raycast(pL, toWall, dist)
    local hitR, hitPosR = Helpers.raycast(pR, toWall, dist)
    if hitL and hitR then
        local edgeRaw = Vector4.new(hitPosL.x - hitPosR.x, hitPosL.y - hitPosR.y, 0, 0)
        if Vector4.Length(edgeRaw) < 0.001 then
            return Vector4.Normalize(Vector4.new(origin.x - hitPos.x, origin.y - hitPos.y, 0, 0))
        end
        local edge = Vector4.Normalize(edgeRaw)
        local n1 = Vector4.new(-edge.y, edge.x, 0, 0)
        local n2 = Vector4.new(edge.y, -edge.x, 0, 0)
        local toPlayer = Vector4.new(origin.x - hitPos.x, origin.y - hitPos.y, 0, 0)
        local d1 = n1.x * toPlayer.x + n1.y * toPlayer.y
        return (d1 > 0) and n1 or n2
    end
    -- Fallback: origin-to-hit direction (inaccurate but functional)
    return Vector4.Normalize(Vector4.new(origin.x - hitPos.x, origin.y - hitPos.y, 0, 0))
end

--- Detect a wall directly in front of the player's camera direction.
--- @param maxDist number|nil Maximum detection distance (defaults to cfg.wallDetectDistance).
--- @param dotThreshold number|nil Minimum forward-to-normal dot product for a valid hit (defaults to -0.5).
--- @return boolean hit Whether a qualifying wall was detected.
--- @return Vector4|nil wallNormal The wall surface normal, or nil on miss.
--- @return number dist Distance to the wall, or 999 on miss.
function WallDetect.detectForwardWall(maxDist, dotThreshold)
    maxDist = maxDist or cfg.wallDetectDistance
    dotThreshold = dotThreshold or -0.5
    local origin = Helpers.getPlayerHipPosition()
    local fwd = Game.GetCameraSystem():GetActiveCameraForward()
    local fwdFlat = Vector4.Normalize(Vector4.new(fwd.x, fwd.y, 0, 0))
    local hit, hitPos, dist = Helpers.raycast(origin, fwdFlat, maxDist)
    if hit then
        local wallNormal = WallDetect.calculateWallNormal(origin, hitPos)
        local dot = fwdFlat.x * wallNormal.x + fwdFlat.y * wallNormal.y
        if dot < dotThreshold then
            return true, wallNormal, dist
        end
    end
    return false, nil, 999
end

--- Detect the nearest wall to the player's left or right using camera and velocity-based raycasts.
--- @return string|nil side The camera-relative side of the wall ("left" or "right"), or nil on miss.
--- @return Vector4|nil hitDir The ray direction that hit the wall, or nil on miss.
--- @return number hitDist Distance to the closest wall, or 999 on miss.
--- @return Vector4|nil hitPos World-space hit position, or nil on miss.
function WallDetect.detectWall()
    local origin = Helpers.getPlayerHipPosition()
    local right  = Helpers.getCameraRightDirection()
    local left   = Vector4.new(-right.x, -right.y, 0, 0)

    local hitR, hitPosR, distR = Helpers.raycast(origin, right, cfg.wallDetectDistance)
    local hitL, hitPosL, distL = Helpers.raycast(origin, left,  cfg.wallDetectDistance)

    -- Also check perpendicular to velocity (finds walls when camera is turned)
    local vel = wallState.player:GetVelocity()
    local speed2D = Vector4.Length2D(vel)
    if speed2D > 1.0 then
        local velFlat = Vector4.Normalize(Vector4.new(vel.x, vel.y, 0, 0))
        local velRight = Vector4.new(-velFlat.y, velFlat.x, 0, 0)
        local velLeft  = Vector4.new(velFlat.y, -velFlat.x, 0, 0)

        local hitVR, hitPosVR, distVR = Helpers.raycast(origin, velRight, cfg.wallDetectDistance)
        local hitVL, hitPosVL, distVL = Helpers.raycast(origin, velLeft,  cfg.wallDetectDistance)

        -- Merge: keep closest hit per side
        if hitVR and (not hitR or distVR < distR) then
            hitR, hitPosR, distR = true, hitPosVR, distVR
            right = velRight
        end
        if hitVL and (not hitL or distVL < distL) then
            hitL, hitPosL, distL = true, hitPosVL, distVL
            left = velLeft
        end
    end

    -- Pick closest hit
    local hitDir, hitDist, hitPos
    if hitR and hitL then
        if distR <= distL then hitDir, hitDist, hitPos = right, distR, hitPosR
        else hitDir, hitDist, hitPos = left, distL, hitPosL end
    elseif hitR then hitDir, hitDist, hitPos = right, distR, hitPosR
    elseif hitL then hitDir, hitDist, hitPos = left, distL, hitPosL
    else return nil, nil, 999, nil end

    -- Determine camera-relative side for tilt direction
    local camRight = Helpers.getCameraRightDirection()
    local dot = hitDir.x * camRight.x + hitDir.y * camRight.y
    local side = (dot > 0) and "right" or "left"
    return side, hitDir, hitDist, hitPos
end

--- Classify whether the player should wall run, wall climb, or neither based on approach angle.
--- Uses side and forward raycasts with velocity and camera direction to determine the action.
--- @param vel Vector4 The player's current velocity vector.
--- @return string|nil action The wall action type ("run", "climb", or nil).
--- @return string|nil side Camera-relative wall side ("left" or "right"), nil for climb.
--- @return Vector4|nil rayDir The ray direction toward the wall, nil for climb.
--- @return Vector4|nil wallNormal The wall surface normal.
--- @return number|nil debugDeg The approach or look angle in degrees for debug display.
function WallDetect.classifyWallAction(vel)
    local origin = Helpers.getPlayerHipPosition()
    local fwd = Game.GetCameraSystem():GetActiveCameraForward()
    local fwdFlat = Vector4.Normalize(Vector4.new(fwd.x, fwd.y, 0, 0))
    local velFlat = Vector4.Normalize(Vector4.new(vel.x, vel.y, 0, 0))

    Helpers.logDebug(string.format("[WallAction] ENTER classify: vel=(%.2f,%.2f) fwd=(%.2f,%.2f) entryAngle=%.1f",
        velFlat.x, velFlat.y, fwdFlat.x, fwdFlat.y, cfg.wallRunEntryAngle))

    -- 1) Check wall climb first: camera within entryAngle degrees of dead-center
    local climbDotThreshold = -math.cos(math.rad(cfg.wallRunEntryAngle))
    local facingWall, climbWallN, climbDist = WallDetect.detectForwardWall(nil, climbDotThreshold)
    if facingWall then
        local lookDot = fwdFlat.x * climbWallN.x + fwdFlat.y * climbWallN.y
        local climbDeg = math.deg(math.acos(math.max(-1, math.min(1, math.abs(lookDot)))))
        local velDot = velFlat.x * climbWallN.x + velFlat.y * climbWallN.y
        Helpers.logDebug(string.format("[WallAction] CLIMB check: lookDot=%.3f climbDeg=%.1f velDot=%.3f sprint=%s wallN=(%.2f,%.2f)",
            lookDot, climbDeg, velDot, tostring(input.pressingSprint), climbWallN.x, climbWallN.y))
        -- Need to be moving toward the wall or sprinting
        if (velDot < -0.3 and Helpers.meetsMinimumSpeed()) or input.pressingSprint then
            Helpers.logDebug("[WallAction] => CLIMB (camera within entry angle)")
            return "climb", nil, nil, climbWallN, climbDeg
        end
        Helpers.logDebug("[WallAction] CLIMB skipped: not moving toward wall and not sprinting")
    else
        Helpers.logDebug(string.format("[WallAction] CLIMB miss: facingWall=false (dotThreshold=%.3f)", climbDotThreshold))
    end

    -- 2) Check wall run: velocity approach angle >= entryAngle
    -- Try side raycasts first, fall back to forward raycast
    local side, rayDir, wallN
    local sideHit, sideRayDir, dist, hitPos = WallDetect.detectWall()
    if sideHit then
        side, rayDir = sideHit, sideRayDir
        wallN = WallDetect.calculateWallNormal(origin, hitPos)
        Helpers.logDebug(string.format("[WallAction] RUN detect: sideHit=%s wallN=(%.2f,%.2f)", side, wallN.x, wallN.y))
    else
        local fwdHit, fwdWallN, fwdDist = WallDetect.detectForwardWall()
        if not fwdHit then
            Helpers.logDebug("[WallAction] => NIL (no side wall, no forward wall)")
            return nil
        end
        wallN = fwdWallN
        rayDir = Vector4.new(-wallN.x, -wallN.y, 0, 0)
        local camRight = Helpers.getCameraRightDirection()
        local dot = rayDir.x * camRight.x + rayDir.y * camRight.y
        side = (dot > 0) and "right" or "left"
        Helpers.logDebug(string.format("[WallAction] RUN detect: fwdFallback side=%s wallN=(%.2f,%.2f)", side, wallN.x, wallN.y))
    end

    local velDot = velFlat.x * wallN.x + velFlat.y * wallN.y
    local approachDeg = math.deg(math.acos(math.max(-1, math.min(1, math.abs(velDot)))))
    Helpers.logDebug(string.format("[WallAction] RUN check: approachDeg=%.1f velDot=%.3f threshold=%.1f",
        approachDeg, velDot, cfg.wallRunEntryAngle))
    if approachDeg >= cfg.wallRunEntryAngle then
        Helpers.logDebug(string.format("[WallAction] => RUN side=%s", side))
        return "run", side, rayDir, wallN, approachDeg
    end

    -- 3) Dead zone fallback: velocity too head-on for wall run, but camera outside
    -- climb window. Heading into a wall → treat as climb.
    if velDot < -0.3 or input.pressingSprint then
        local lookDot = fwdFlat.x * wallN.x + fwdFlat.y * wallN.y
        local fallbackDeg = math.deg(math.acos(math.max(-1, math.min(1, math.abs(lookDot)))))
        Helpers.logDebug(string.format("[WallAction] => CLIMB (dead zone fallback) deg=%.1f", fallbackDeg))
        return "climb", nil, nil, wallN, fallbackDeg
    end

    Helpers.logDebug(string.format("[WallAction] => NIL (approachDeg=%.1f < threshold, not moving toward wall)", approachDeg))
    return nil
end

--- Qualify a wall action from IDLE state by applying cooldown, airborne, and speed gates before classification.
--- @param vel Vector4 The player's current velocity vector.
--- @return string|nil action The wall action type ("run", "climb", or nil).
--- @return string|nil side Camera-relative wall side ("left" or "right"), nil for climb.
--- @return Vector4|nil rayDir The ray direction toward the wall, nil for climb.
--- @return Vector4|nil wallNormal The wall surface normal.
--- @return number|nil debugDeg The approach or look angle in degrees for debug display.
function WallDetect.qualifyWallAction(vel)
    -- Wall run gates
    local canRun = not wallState.wallRunUsedThisJump and wallState.airborneTime > 0.15
                   and wallState.cooldown > cfg.exitCooldown and Helpers.meetsMinimumSpeed()
    -- Wall climb gates
    local canClimb = not wallState.wallClimbUsedThisJump and wallState.airborneTime > 0.1
    if not canRun and not canClimb then
        Helpers.logDebug(string.format("[Qualify] BLOCKED: canRun=%s canClimb=%s usedJump=%s airborne=%.2f cooldown=%.2f exitCD=%.2f usedClimb=%s",
            tostring(canRun), tostring(canClimb), tostring(wallState.wallRunUsedThisJump), wallState.airborneTime, wallState.cooldown, cfg.exitCooldown, tostring(wallState.wallClimbUsedThisJump)))
        return nil
    end

    local action, side, rayDir, wallN, deg = WallDetect.classifyWallAction(vel)
    if action == "climb" and not canClimb then
        Helpers.logDebug("[Qualify] classify=climb but canClimb=false, rejected")
        return nil
    end
    if action == "run" and not canRun then
        Helpers.logDebug(string.format("[Qualify] classify=run but canRun=false: usedJump=%s airborne=%.2f cooldown=%.2f",
            tostring(wallState.wallRunUsedThisJump), wallState.airborneTime, wallState.cooldown))
        return nil
    end
    return action, side, rayDir, wallN, deg
end

return WallDetect
