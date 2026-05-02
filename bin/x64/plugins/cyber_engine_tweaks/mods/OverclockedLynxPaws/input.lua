local input = {
    pressingJump       = false,
    jumpJustPressed    = false,
    crouchJustPressed  = false,
    backJustPressed    = false,
    pressingBack       = false,
    keyboardBack       = false,
    padBack            = false,
    pressingSprint     = false,
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
