local cfg = require("config").cfg
local state = require("state")
local wallState = state.wallState
local camera = state.camera
local Helpers = require("helpers")
local WallDetect = require("walldetect")

local Debug = {}

--- Build the debug text string from current wall state, storing it in wallState.debugText.
--- @param LynxPaw table The LynxPaw module for equipment status.
--- @param airborne boolean Whether the player is currently airborne.
function Debug.buildText(LynxPaw, airborne)
    if not cfg.debugEnabled then
        wallState.debugText = ""
        return
    end

    local vel = wallState.player:GetVelocity()
    local popTag = wallState.capsuleReset and " | CAP_RESET" or ""
    local lynxTag = cfg.requireLynxPaws and (LynxPaw.equipped and " | Lynx: YES" or " | Lynx: NO") or " | Lynx: OFF"
    local dashTag = string.format(" | Loco: %d | AirDash: %s | AimHold: %.2f",
        Helpers.getLastLocomotionState(), tostring(Helpers.isAirDashing()), cfg.wallKickAimHold)

    local fallBB = Helpers.getPlayerBlackboard()
    local fallState = fallBB and fallBB:GetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.Fall) or -1
    local landState = fallBB and fallBB:GetInt(Game.GetAllBlackboardDefs().PlayerStateMachine.Landing) or -1
    local fallTag = string.format(" | Fall: %d | Land: %d", fallState, landState)

    local safeLandTag = ""
    if wallState.crouchBuffered then
        local remaining = cfg.safeLandWindow - wallState.crouchBufferTimer
        safeLandTag = string.format(" | SafeLand: READY %.2f/%.2fs", remaining, cfg.safeLandWindow)
        wallState.safeLandDebugText = safeLandTag
    elseif wallState.safeRollTimer then
        local t = wallState.safeRollTimer / wallState.safeRollDuration
        safeLandTag = string.format(" | SafeLand: ROLL %.0f%%", t * 100)
        wallState.safeLandDebugText = safeLandTag
    elseif wallState.safeLandDebugText then
        safeLandTag = wallState.safeLandDebugText
    end

    wallState.debugText = string.format(
        "WallRun: %s | Air: %.2fs | Timer: %.1f | Side: %s | Spd: %.1f/%.1f | VelZ: %.1f | Tilt: %.0f%s%s%s%s%s",
        wallState.phase,
        wallState.airborneTime,
        wallState.timer,
        tostring(wallState.wallSide),
        Vector4.Length2D(vel),
        cfg.minHorizSpeed,
        vel.z,
        camera.tilt,
        popTag,
        lynxTag,
        dashTag,
        fallTag,
        safeLandTag
    )

    if wallState.phase == "WALL_CLIMBING" and wallState.climbEntryDeg then
        wallState.debugText = wallState.debugText .. string.format(" | ClimbDeg: %.1f", wallState.climbEntryDeg)
    end

    if wallState.phase == "IDLE" and airborne and wallState.airborneTime > 0.15
       and vel.z >= 0 and Vector4.Length2D(vel) > cfg.minHorizSpeed then
        local side, rayDir, dist, hitPos = WallDetect.detectWall()
        if not side then
            wallState.debugText = wallState.debugText .. " | WR: no wall"
        else
            local wallN = WallDetect.calculateWallNormal(Helpers.getPlayerHipPosition(), hitPos)
            local runDir = WallDetect.calculateWallRunDirection(wallN)
            local fwd = Game.GetCameraSystem():GetActiveCameraForward()
            local fwdFlat = Vector4.Normalize(Vector4.new(fwd.x, fwd.y, 0, 0))
            local lookAlign = fwdFlat.x * runDir.x + fwdFlat.y * runDir.y
            local lookToward = fwdFlat.x * (-wallN.x) + fwdFlat.y * (-wallN.y)
            wallState.debugText = wallState.debugText .. string.format(
                " | WR: %s d=%.2f align=%.2f toward=%.2f",
                side, dist, lookAlign, lookToward
            )
        end
    end
end

--- Draw the ImGui debug overlay window showing wall run state information.
function Debug.drawOverlay()
    if wallState.debugText == "" then return end
    ImGui.SetNextWindowPos(300, 10)
    local flags = ImGuiWindowFlags.NoTitleBar
               + ImGuiWindowFlags.NoResize
               + ImGuiWindowFlags.NoMove
               + ImGuiWindowFlags.NoBackground
               + ImGuiWindowFlags.AlwaysAutoResize
    if ImGui.Begin("WallRunDebug", flags) then
        ImGui.Text(wallState.debugText)
    end
    ImGui.End()
end

return Debug
