local input = {
    pressingJump       = false,
    jumpJustPressed    = false,
    crouchJustPressed  = false,
    backJustPressed    = false,
    pressingBack       = false,
    keyboardBack       = false,
    padBack            = false,
    pressingSprint     = false,  -- sprint INTENT: KBM latch OR wr_sprint_held fact (key down or PSM SprintToggled); used by standstill climb + safe-roll sprint resume
    sprintKeyHeld      = false,  -- sprint key PHYSICALLY down right now (wr_sprint_key fact only); used by the requireSprint gate
    sprintHeldKBM      = false,  -- KBM hold latch from OnAction; fallback for pressingSprint only when the redscript bridge is absent
    meleeJustPressed   = false,
    weaponSwitchJustPressed = false,
    -- Custom CET hotkey flags (set by hotkey callbacks, reset each frame)
    reverseHangJustPressed = false,
    dismountJustPressed    = false,
    safeRollJustPressed    = false,
    -- Cached binding state, refreshed every 2s during settings sync.
    -- When true, the original key path is bypassed for that action.
    hotkeyBound = {
        reverseHang = false,
        dismount    = false,
        safeRoll    = false,
    },
}

return input
