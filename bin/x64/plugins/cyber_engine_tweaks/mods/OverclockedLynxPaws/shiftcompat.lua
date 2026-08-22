--[[
    Shift (CyanideX's FPP camera mod) compatibility layer.

    Shift >= 1.12 drives the player's FPP camera component through a compositor
    that writes SetLocalPosition / SetLocalOrientation every frame whenever its
    pose is non-neutral (any saved unarmed/weapon preset with offsets) or a shake
    layer is active. CET ticks mods in folder-name order, so Shift's write lands
    after ours and erases our wall-run tilt, mantis/reverse-hang pitch and the
    safe-roll camera drop + spin.

    Shift's public API (GetMod("Shift").api) does not export its "skip hardware
    write" flag, so while we own the camera we freeze Shift outright with
    api.Disable() (its whole update loop early-returns) and hand it back with
    api.Enable() once our camera is at rest. If Shift ever ships an
    api.SetExternalCameraOwner(id, active) we use that instead.

    Guarantees:
      * Shift absent, or disabled by the user -> this module never touches it.
      * Every exit path re-enables: hysteresis release, our shutdown, player
        detach, Shift hot-reload mid-window.
      * Crash mid-window: a marker file in our mod dir survives; on the next
        session we re-enable Shift as soon as its API is visible (also from the
        main menu) and clear the marker.

    Timing: our onUpdate runs before Shift's in the same frame, so Disable()
    issued here takes effect before Shift's compositor would have written —
    zero stomped frames at acquire.
]]

local state = require("state")
local wallState = state.wallState
local camera = state.camera
local Helpers = require("helpers")
local SafeLanding = require("safelanding")

local ShiftCompat = {}

local OWNER_ID          = "OverclockedLynxPaws"
local MARKER_FILE       = "shift_owner.flag"  -- relative: resolves inside our mod dir
local RELEASE_HYSTERESIS = 0.35  -- seconds after our camera goes quiet before release
local LOOKUP_INTERVAL   = 2.0    -- seconds between GetMod("Shift") re-resolves

local api          = nil    -- cached GetMod("Shift").api, or nil
local hasUpstream  = false  -- api.SetExternalCameraOwner available
local lookupTimer  = LOOKUP_INTERVAL  -- resolve on the first tick
local owned        = false  -- we currently claim the camera
local weDisabled   = false  -- we flipped Shift's modEnabled off and must restore it
local releaseTimer = nil    -- hysteresis countdown while owned but quiet
local releaseStep  = nil    -- "refresh": re-apply Shift's preset next frame

---------------------------------------------------------------------------
-- Guarded access
---------------------------------------------------------------------------

--- Call a Shift API function by name. Every Shift access goes through here:
--- nil api, missing function, or a thrown error all collapse to nil.
local function call(fnName, ...)
    if not api then return nil end
    local f = api[fnName]
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, ...)
    if not ok then
        Helpers.logDebug("[ShiftCompat] api." .. fnName .. " failed: " .. tostring(r))
        return nil
    end
    return r
end

local function readMarker()
    local ok, f = pcall(io.open, MARKER_FILE, "r")
    if not ok or not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function writeMarker(v)
    local ok, f = pcall(io.open, MARKER_FILE, "w")
    if not ok or not f then return end
    f:write(v)
    f:close()
end

---------------------------------------------------------------------------
-- Discovery / recovery
---------------------------------------------------------------------------

--- If a previous session left Shift disabled on our behalf (crash mid-window),
--- re-enable it and clear the marker. Only runs when we are not holding it now.
local function recover()
    if weDisabled or not api then return end
    if readMarker() ~= "1" then return end
    if not call("IsEnabled") then
        if call("Enable") then
            Helpers.logDebug("[ShiftCompat] re-enabled Shift left disabled by a previous session")
        else
            return  -- keep the marker; retry on the next resolve
        end
    end
    writeMarker("0")
end

--- (Re)resolve GetMod("Shift"). Shift loads after us alphabetically and can be
--- hot-reloaded at any time, so the cached api table can appear, vanish or be
--- replaced; we only react on identity change.
local function resolveApi()
    local ok, mod = pcall(GetMod, "Shift")
    local found = nil
    if ok and type(mod) == "table" and type(mod.api) == "table" then
        found = mod.api
    end
    if found == api then return end
    api = found
    hasUpstream = api ~= nil and type(api.SetExternalCameraOwner) == "function"
    if api then
        Helpers.logDebug("[ShiftCompat] Shift API " .. (hasUpstream and "(with external-owner support)" or "(freeze mode)"))
        -- A Shift hot-reload mid-window comes back disabled from disk; if we
        -- still own the camera that is exactly the state we want, and the
        -- release path re-enables the new instance. Otherwise recover.
        if not (owned and weDisabled) then recover() end
    end
end

---------------------------------------------------------------------------
-- Ownership
---------------------------------------------------------------------------

--- True whenever our mod is writing (or about to write) the FPP camera.
--- Reads only our own state; mirrors every camera-control path in phases.lua
--- and safelanding.lua.
local function wantsOwnership()
    if not wallState.player then return false end
    if wallState.phase ~= "IDLE" then return true end        -- every wall / hang / mount phase
    if camera.tilt ~= 0 then return true end                 -- IDLE unroll lerp still writing
    if SafeLanding.isRollActive() then return true end       -- safe roll drop / spin / standup
    if wallState.chainScanTimer then return true end         -- post-kick arc: hold through chains
    return false
end

local function acquire()
    resolveApi()
    owned = true
    weDisabled = false
    releaseTimer = nil
    releaseStep = nil
    if not api then return end
    -- The user keeps Shift disabled: never touch it.
    if not call("IsEnabled") then return end
    if hasUpstream then
        call("SetExternalCameraOwner", OWNER_ID, true)
        return
    end
    -- Marker first: if we crash between here and the Enable, the next session
    -- knows to restore. Disable() persists modEnabled=false to Shift's settings.
    writeMarker("1")
    if call("Disable") then
        weDisabled = true
    else
        writeMarker("0")
    end
end

--- Hand the camera back. Smooth path (normal release): clear Shift's preset
--- sources to a zero pose while keeping its FOV, enable, then next frame ask
--- Shift to re-apply the active preset so it eases back in from where we left
--- the camera instead of snapping. Immediate path (shutdown / detach): enable
--- only; the preset snaps back.
local function doRelease(immediate)
    resolveApi()
    if weDisabled then
        if not immediate and call("IsWeaponCameraEnabled") then
            local fov = call("GetFOV")
            call("ResetCamera", 0)
            if type(fov) == "number" then call("SetFOV", fov, 0) end
            releaseStep = "refresh"
        end
        if call("Enable") then
            writeMarker("0")
            weDisabled = false
        end
        -- else: Shift gone or errored; keep weDisabled + marker and retry later.
    end
    if hasUpstream then
        call("SetExternalCameraOwner", OWNER_ID, false)
    end
    owned = false
    releaseTimer = nil
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

--- Per-frame tick. Called from init.lua's onUpdate, outside the `loaded` gate
--- so crash recovery also runs in the main menu.
--- @param dt number Delta time in seconds.
function ShiftCompat.update(dt)
    lookupTimer = lookupTimer + dt
    if lookupTimer >= LOOKUP_INTERVAL then
        lookupTimer = 0
        resolveApi()
        -- A failed re-enable (Shift missing at release time) gets retried.
        if not owned and weDisabled then doRelease(true) end
    end

    if releaseStep == "refresh" then
        releaseStep = nil
        call("SetWeaponCameraEnabled", true)
    end

    if wantsOwnership() then
        if not owned then acquire() end
        releaseTimer = nil
    elseif owned then
        releaseTimer = (releaseTimer or RELEASE_HYSTERESIS) - dt
        if releaseTimer <= 0 then doRelease(false) end
    end
end

--- Force release (shutdown, player detach). Safe to call when not owned.
--- @param immediate boolean Skip the smooth re-apply; preset snaps back.
function ShiftCompat.release(immediate)
    if owned then doRelease(immediate) end
    releaseStep = nil
end

function ShiftCompat.isOwned()
    return owned
end

--- Short status string for the debug overlay.
function ShiftCompat.debugTag()
    if not api then return " | Shift: absent" end
    if owned then
        if releaseTimer then return string.format(" | Shift: rel %.2f", releaseTimer) end
        return weDisabled and " | Shift: OWNED" or " | Shift: owned (untouched)"
    end
    return " | Shift: idle"
end

return ShiftCompat
