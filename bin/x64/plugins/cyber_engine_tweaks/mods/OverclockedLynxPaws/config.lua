local cfg = {
    enabled           = true,
    debugEnabled      = false,
    cetLogsEnabled    = false,
    requireLynxPaws   = true,   -- gate wall running on Lynx Paw cyberware
    wallRunSpeed      = 6.0,
    unlimitedWallRun    = false,
    wallRunDuration   = 1.5,
    riseSpeed         = 2.0,
    sinkRate          = 2.0,
    wallKickForce     = 12.0,
    wallDetectDistance = 1.3,
    minHorizSpeed     = 5.0,
    exitCooldown      = 0.5,
    targetWallDist    = 0.6,
    cameraTilt        = 21.0,   -- roll degrees away from wall
    cameraYawOffset   = 35.0,   -- yaw degrees away from wall (applied once on entry)
    cameraLerpSpeed   = 4.0,    -- how fast camera roll lerps
    impulseGain       = 8.0,    -- velocity correction strength (higher = snappier)
    aimSensitivity     = 1.0,    -- multiplier for aim sensitivity during wall actions
    triggerKerenzikov  = true,   -- activate kerenzikov during wall run aim / wall kick
    unlimitedWallClimb  = false,
    unlimitedWallSlide  = false,
    wallClimbDuration  = 0.50, -- max wall climb time (seconds)
    wallSlideDuration  = 1.5,  -- max wall slide time (seconds)
    chainBonusDuration = 1.0,   -- extra wall run duration on chain (seconds)
    unlimitedWallChains = false,
    maxWallChains      = 2,     -- max wall-to-wall chains per airborne period
    unlimitedHangtime   = false,
    wallKickAimHold    = 0.25,  -- seconds to hold position before kick
    safeLandWindow     = 0.30,  -- seconds before landing to buffer crouch
    safeLandAnyHeight  = false, -- survive even lethal falls (loco 26)
    gainShinobiSkill   = true,  -- award Shinobi (Reflexes) skill XP for wall actions
    requireSprint      = false, -- require sprint key held for wall run/climb
    drainStamina       = true,  -- drain stamina during wall actions
    staminaScalesShinobi = true, -- scale stamina reduction with Shinobi (false = Lynx Paw tier)
    wallRunEntryAngle  = 15.0, -- min approach angle for wall run (below = climb)
}

-- All Redscript-exposed fields to sync from WallRunSettings
local syncFields = {
    "enabled", "debugEnabled", "cetLogsEnabled", "requireLynxPaws",
    "wallRunDuration", "wallClimbDuration", "wallSlideDuration",
    "maxWallChains", "chainBonusDuration", "aimSensitivity",
    "triggerKerenzikov", "wallKickAimHold", "wallKickForce",
    "cameraTilt", "safeLandWindow", "safeLandAnyHeight",
    "unlimitedWallRun", "unlimitedWallClimb", "unlimitedWallSlide",
    "unlimitedHangtime", "unlimitedWallChains",
    "gainShinobiSkill", "requireSprint", "drainStamina", "staminaScalesShinobi", "wallRunEntryAngle",
}

--- Synchronize mod configuration values from the Redscript WallRunSettings scriptable system.
local function syncSettings()
    local ok, sys = pcall(function()
        return Game.GetScriptableSystemsContainer():Get("OverclockedLynxPaws.WallRunSettings")
    end)
    if ok and sys then
        for _, field in ipairs(syncFields) do
            local fok, val = pcall(function() return sys[field] end)
            if fok and val ~= nil then cfg[field] = val end
        end
    end
end

return {
    cfg = cfg,
    syncSettings = syncSettings,
}
