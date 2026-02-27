local wallState = {
    player       = nil,
    phase        = "IDLE",       -- IDLE | WALL_RUNNING | WALL_CLIMBING | WALL_SLIDING | REVERSE_WALL_HANG | WALL_JUMP_AIM | WALL_JUMPING | AIR_HOVER | EXIT_PUSH | LEDGE_MOUNTING
    wallSide     = nil,          -- "left" | "right"
    wallNormal   = nil,          -- Vector4 (XY), points away from wall
    wallRunDir   = nil,          -- Vector4 (XY), travel direction along wall
    timer        = 0,            -- remaining wall-run time
    climbTimer   = 0,            -- elapsed wall climb time
    airborneTime = 0,            -- seconds airborne
    cooldown     = 0,            -- seconds since last wall-run exit
    wallRunUsedThisJump = false,        -- only one wall run per airborne period
    wallClimbUsedThisJump = false,       -- only one wall climb per airborne period
    chainCount   = 0,            -- wall-to-wall chains used this airborne period
    slideBudget  = 0,            -- remaining wall slide time this airborne period
    -- Jump / exit push fields
    kickDirection      = nil,          -- Vector4, impulse direction
    phaseTimer    = 0,
    aimDuration = 0.35,
    aimStartTilt = 0,
    -- Height tracking
    entryZ       = 0,            -- Z position when wall run started
    targetZ      = 0,            -- current desired Z (entryZ + accumulated vertical offset)
    footstepTimer = 0,           -- timer for footstep sound playback
    debugText    = "",

    -- Wall-run entry / curve detection
    wallRunEntryNormal = nil,    -- Vector4 (XY), wall normal at time of entry (for curve check)
    lastKickWallNormal = nil,    -- Vector4 (XY), wall normal from last kick (for same-wall check)

    -- Wall climb
    isClimbBlocked     = false,  -- quest fact is active blocking game climb
    climbPeakHoldTimer = nil,    -- countdown before transitioning out of climb peak
    climbEntryDeg      = nil,    -- approach angle at climb entry (debug)

    -- Wall jump aim hold position
    aimHoldX = nil,              -- X position to hold during aim phase
    aimHoldY = nil,              -- Y position to hold during aim phase
    aimHoldZ = nil,              -- Z position to hold during aim phase

    -- Exit push (momentum after failed chain)
    exitPushSpeed     = nil,     -- horizontal speed during exit push
    exitPushGrounded  = false,   -- true once player touches ground during push
    exitPushLandTime  = 0,       -- phaseTimer value when grounding occurred
    exitPushDuration  = nil,     -- total push duration
    exitPushVelocityZ = nil,     -- initial vertical velocity at push start
    exitPushUpSpeed   = nil,     -- upward speed component

    -- Reverse wall hang (backward + jump → aim transition)
    reverseHangTimer    = nil,   -- elapsed time in reverse hang transition
    reverseHangDuration = 0.388, -- how long the camera turn takes
    reverseHangYawStart = 0,     -- starting yaw
    reverseHangYawEnd   = 0,     -- target yaw (facing away from wall)
    reverseHangPos      = nil,   -- position to hold during transition
    reverseHangNormal   = nil,   -- saved wall normal for aim phase
    reverseHangDone     = false, -- true when yaw transition is complete

    -- Dash takeover
    isDashTakeover        = false,  -- true when mod intercepted an air dash
    wasAirborneBeforeDash = false,  -- airborne state before dash started

    -- Post-kick chain detection
    pendingKickImpulse  = nil,   -- Vector4, deferred impulse applied next frame
    chainScanTimer      = nil,   -- elapsed time scanning for chain targets
    chainScanDirection  = nil,   -- Vector4, kick direction for chain scan

    -- Air hover (Air Kerenzikov perk)
    hoverTimer = nil,            -- elapsed hover time
    hoverX     = nil,            -- X position to hold during hover
    hoverY     = nil,            -- Y position to hold during hover
    hoverZ     = nil,            -- Z position to hold during hover

    -- Kerenzikov state
    kerenzikovActive = false,    -- true when time dilation is active

    -- Misc
    capsuleReset   = false,      -- single-frame flag to remove ForceCrouch after ledge mount
    snapTimer      = nil,        -- wall-lost grace timer during climb
    wallLostTimer  = nil,        -- wall-lost grace timer (general)
    airPeakZ       = nil,        -- highest Z reached this airborne period

    -- Crouch buffer / safe landing
    crouchBuffered    = false,
    crouchBufferTimer = 0,
    crouchBufferUsed  = false,   -- one-shot per airborne period

    -- Safe roll state
    safeRollTimer          = nil,     -- elapsed time in roll
    safeRollDuration       = 0.75,    -- total roll duration (seconds)
    safeRollDir            = nil,     -- Vector4, normalized forward direction
    safeRollSpeed          = 12.0,    -- forward teleport speed (m/s)
    safeRollYaw            = 0,       -- player yaw during roll
    safeRollUncrouch       = nil,     -- countdown to remove ForceCrouch after roll
    safeRollSprintTimer    = nil,     -- countdown to resume sprint after uncrouch
    safeRollCleanupTimer   = nil,     -- countdown to clear quest facts after roll
    safeRollSoundCountdown = nil,     -- countdown to stop roll sound effect
    safeRollMeshIsHidden   = false,   -- true while player mesh is hidden during roll
    safeRollShouldReequip  = false,   -- true if weapon was holstered for roll
    safeLandDebugText      = nil,     -- cached debug text for safe landing state
}

local camera = {
    tilt          = 0,    -- current roll angle (degrees)
    targetTilt    = 0,
    rollBlendProgress    = 0,    -- 0→1 for roll transition
    trackedYaw      = 0,    -- accumulated mouse yaw (set on wall-run entry, updated from input)
    pendingMouseDeltaX   = 0,    -- raw mouse X delta this frame (consumed each update)
    rightStickX        = 0,    -- controller right stick X axis (-1 to 1, continuous)
}

local ledgeMount = {
    startPos  = nil,   -- Vector4, position when mount began
    landPos   = nil,   -- Vector4, target landing position on top of ledge
    peakZ     = 0,     -- Z height for the arc apex (above ledge)
    startYaw  = 0,
    targetYaw = 0,
    startTilt = 0,     -- camera roll at mount start
    timer     = 0,
    duration  = 0.6,
    -- Precomputed Z quadratic coefficients: z(t) = A*t² + B*t + C
    zA = 0, zB = 0, zC = 0,
}

return {
    wallState = wallState,
    camera = camera,
    ledgeMount = ledgeMount,
}
