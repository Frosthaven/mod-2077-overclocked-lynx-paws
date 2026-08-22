--[[
    Overclocked Lynx Paws - Cyberpunk 2077 CET Mod
    Implements wall running using impulse-based velocity correction for movement
    (preserves full mouse control), and FPP camera component for roll effects.
]]

OverclockedLynxPaws = { loaded = false }

function OverclockedLynxPaws:New()
    -- registerInput fires on press AND release (with isDown bool); we only
    -- raise the just-pressed flag on press for snap-action feel. Bindings
    -- still appear in the same CET bindings UI as registerHotkey would.
    registerInput("OLP_ReverseHang", "Reverse Wall Hang", function(isDown)
        if isDown then require("input").reverseHangJustPressed = true end
    end)
    registerInput("OLP_DismountWall", "Dismount Wall", function(isDown)
        if isDown then require("input").dismountJustPressed = true end
    end)
    registerInput("OLP_SafeLandingRoll", "Safe Landing Roll", function(isDown)
        if isDown then require("input").safeRollJustPressed = true end
    end)

    registerForEvent("onInit", function()
        local config = require("config")
        local state = require("state")
        local wallState = state.wallState
        local camera = state.camera
        local input = require("input")
        local Helpers = require("helpers")
        local Kerenzikov = require("kerenzikov")
        local LynxPaw = require("lynxpaw")
        local Phases = require("phases")
        local Debug = require("debug")
        local Mantis = require("mantis")
        local ShiftCompat = require("shiftcompat")

        Helpers.init()

        if Game.GetPlayer()
           and Game.GetPlayer():IsAttached()
           and not Game.GetSystemRequestsHandler():IsPreGame() then
            self:Setup()
        end

        Observe('QuestTrackerGameController', 'OnInitialize', function()
            if not self.loaded then
                self:Setup()
            end
        end)

        Observe('QuestTrackerGameController', 'OnUninitialize', function()
            if Game.GetPlayer() == nil then
                -- Player is gone (save load / main menu): give Shift its camera
                -- back now rather than holding it across the transition.
                if self._ShiftCompat then pcall(self._ShiftCompat.release, true) end
                wallState.player  = nil
                self.loaded = false
            end
        end)

        Observe("PlayerPuppet", "OnAction", function(_, action, consumer)
            if not self.loaded then return end
            local name  = Game.NameToString(action:GetName())
            local atype = action:GetType(action).value
            if name == "Jump" then
                if atype == "BUTTON_PRESSED" then
                    input.pressingJump    = true
                    input.jumpJustPressed = true
                elseif atype == "BUTTON_RELEASED" then
                    input.pressingJump = false
                end
            end
            if name == "Crouch" or name == "ToggleCrouch" then
                if atype == "BUTTON_PRESSED" or atype == "BUTTON_HOLD_COMPLETE" then
                    input.crouchJustPressed = true
                end
            end
            if name == "Back" then
                if atype == "BUTTON_PRESSED" then
                    input.backJustPressed = true
                    input.keyboardBack = true
                elseif atype == "BUTTON_RELEASED" then
                    input.keyboardBack = false
                end
                input.pressingBack = input.keyboardBack or input.padBack
            end
            -- KBM hold-to-sprint latch. Feeds only the sprint INTENT flag
            -- (input.pressingSprint) as a fallback; the authoritative signals
            -- (incl. controller Toggle Sprint, which only taps here) are the
            -- redscript wr_sprint_key / wr_sprint_held facts, read in onUpdate.
            if name == "Sprint" or name == "ToggleSprint" then
                if atype == "BUTTON_PRESSED" then
                    input.sprintHeldKBM = true
                elseif atype == "BUTTON_RELEASED" then
                    input.sprintHeldKBM = false
                end
            end
            local isMeleeAction = name == "MeleeAttack" or name == "MeleeLightAttack"
                or name == "MeleeHeavyAttack" or name == "QuickMelee"
            if isMeleeAction then
                if atype == "BUTTON_PRESSED" then
                    input.meleeJustPressed = true
                end
                -- Consume melee during wall phases to block native attack animation
                if wallState.phase ~= "IDLE" and Mantis.checkEquipped() then
                    ListenerActionConsumer.Consume(consumer)
                end
            end
            if atype == "BUTTON_PRESSED" and (
                   name == "WeaponSlot1" or name == "WeaponSlot2"
                or name == "WeaponSlot3" or name == "WeaponSlot4"
                or name == "NextWeapon" or name == "PreviousWeapon"
                or name == "WeaponWheel" or name == "HolsterWeapon"
                or name == "SwitchItem"
                or name == "CombatGadget" or name == "UseCombatGadget"
                or name == "UseConsumable") then
                if wallState.phase == "MANTIS_GRAB" then
                    input.weaponSwitchJustPressed = true
                end
            end
            -- Capture aim input for manual yaw/pitch tracking during wall phases
            if name == "CameraMouseX" then
                local v = action:GetValue(action)
                camera.pendingMouseDeltaX = camera.pendingMouseDeltaX + v
                if v ~= 0 then camera.lastLookGamepad = false end
            elseif name == "CameraMouseY" then
                local v = action:GetValue(action)
                camera.pendingMouseDeltaY = camera.pendingMouseDeltaY + v
                if v ~= 0 then camera.lastLookGamepad = false end
            elseif name == "right_stick_x" then
                camera.rightStickX = action:GetValue(action)
                if math.abs(camera.rightStickX) > 0.1 then camera.lastLookGamepad = true end
            elseif name == "right_stick_y" then
                camera.rightStickY = action:GetValue(action)
                if math.abs(camera.rightStickY) > 0.1 then camera.lastLookGamepad = true end
            end
            -- Controller left stick Y: treat pull-back as pressingBack
            if name == "left_stick_y" then
                input.padBack = action:GetValue(action) < -0.5
                input.pressingBack = input.keyboardBack or input.padBack
            end
        end)

        -- Hook game climb/vault: trigger our ledge mount only during wall climb.
        -- Wall RUN deliberately yields to the game's native climb/vault so the
        -- player isn't pulled up onto a ledge mid-run against their intent.
        local WallDetect = require("walldetect")
        local function onClimbOrVault()
            if wallState.phase == "IDLE" or wallState.phase == "LEDGE_MOUNTING" then return end
            if wallState.phase ~= "WALL_CLIMBING" then
                Phases.yieldToGame()
                return
            end
            local wn = wallState.wallNormal or wallState.lastKickWallNormal
            if not wn then
                local hit, normal = WallDetect.detectForwardWall()
                if hit then wn = normal end
            end
            if wn then Phases.beginLedgeMount(wn) else Phases.yieldToGame() end
        end
        Observe("ClimbEvents", "OnEnter", function(_, stateContext, scriptInterface)
            onClimbOrVault()
        end)
        Observe("VaultEvents", "OnEnter", function(_, stateContext, scriptInterface)
            onClimbOrVault()
        end)

        -- Store module references for Setup and event handlers
        self._config = config
        self._Helpers = Helpers
        self._LynxPaw = LynxPaw
        self._Kerenzikov = Kerenzikov
        self._Phases = Phases
        self._Debug = Debug
        self._input = input
        self._camera = camera
        self._wallState = wallState
        self._ShiftCompat = ShiftCompat
    end)

    registerForEvent("onShutdown", function()
        if self._LynxPaw then self._LynxPaw.cleanupCrouchSpeed() end
        local ok, SafeLanding = pcall(require, "safelanding")
        if self._wallState and self._wallState.player then
            if self._Kerenzikov and self._wallState.phase ~= "IDLE" then
                self._Kerenzikov.deactivate()
            end
            -- Unwind a mid-flight safe roll (camera drop / spin, hidden mesh,
            -- ForceCrouch), then hand the camera back fully: identity
            -- orientation + zero offset, whatever phase we were in.
            if ok and SafeLanding and SafeLanding.abortRoll then
                pcall(SafeLanding.abortRoll, "shutdown")
            end
            if self._Helpers then self._Helpers.resetCameraTransform() end
        end
        if self._Helpers and self._wallState and self._wallState.camSensActive then
            self._Helpers.applyWallCamSens(1.0)
            self._wallState.camSensActive = false
        end
        -- Clear mod facts so a CET reload mid-flight can't leave the Redscript
        -- hooks reading stale state (e.g. wr_safe_land = 1 forever).
        if ok and SafeLanding and SafeLanding.clearAllFacts then
            SafeLanding.clearAllFacts()
        end
        if self._input then
            self._input.sprintHeldKBM  = false
            self._input.sprintKeyHeld  = false
            self._input.pressingSprint = false
        end
        -- Give Shift its camera back. Our onShutdown runs before Shift's own
        -- shutdown save (CET fires mods alphabetically), so the re-enable lands
        -- in its settings file.
        if self._ShiftCompat then pcall(self._ShiftCompat.release, true) end
        if self._wallState then self._wallState.player = nil end
        self.loaded = false
    end)

    registerForEvent("onUpdate", function(delta)
        if self.loaded and self._Phases then
            -- Sprint bridge (must run before Phases.update consumes it):
            --   sprintKeyHeld  = the sprint key / stick click is physically down
            --                    right now (wr_sprint_key, fact only). Feeds the
            --                    requireSprint gate. No KBM latch here: requireSprint
            --                    is only reachable via Mod Settings, so hooks.reds is
            --                    live and the fact is authoritative; OR-ing the latch
            --                    would let a missed BUTTON_RELEASED hold the gate open.
            --   pressingSprint = sprint intent (key down OR the PSM's latched
            --                    SprintToggled, i.e. toggle-sprint / controller stick
            --                    click), KBM latch as fallback. Feeds the standstill
            --                    climb and the safe-roll sprint resume.
            local keyFact, heldFact = false, false
            local qs = Game.GetQuestsSystem()
            if qs then
                keyFact  = qs:GetFact(CName.new("wr_sprint_key")) > 0
                heldFact = qs:GetFact(CName.new("wr_sprint_held")) > 0
            end
            self._input.sprintKeyHeld  = keyFact
            self._input.pressingSprint = self._input.sprintHeldKBM or heldFact

            -- pcall so a Lua error inside a phase handler can't starve the
            -- Shift release below (Shift would otherwise stay frozen all session).
            local okUpd, err = pcall(self._Phases.update, delta, self._config.syncSettings, self._LynxPaw)
            if not okUpd then print("[OLP] Phases.update error: " .. tostring(err)) end
            self._input.jumpJustPressed = false
            self._input.crouchJustPressed = false
            self._input.backJustPressed = false
            self._input.meleeJustPressed = false
            self._input.weaponSwitchJustPressed = false
            self._input.reverseHangJustPressed = false
            self._input.dismountJustPressed    = false
            self._input.safeRollJustPressed    = false
            self._camera.pendingMouseDeltaX = 0
            self._camera.pendingMouseDeltaY = 0
        end

        -- Shift camera hand-off. Runs even before Setup (main menu) so a Shift
        -- left disabled by a crash mid-window is re-enabled as soon as its API
        -- is visible. No-op when Shift is not installed.
        if self._ShiftCompat then self._ShiftCompat.update(delta) end
    end)

    registerForEvent("onDraw", function()
        if self.loaded and self._Debug then
            self._Debug.drawOverlay()
        end
    end)
end

function OverclockedLynxPaws:Setup()
    local state = require("state")
    local wallState = state.wallState
    wallState.player = Game.GetPlayer()

    local Helpers = require("helpers")
    Helpers.init()

    -- Wipe any mod quest facts that might have been saved into the playthrough
    -- (e.g. wr_safe_land left at 1 from a prior session). The Redscript hooks
    -- start firing immediately on game load, so stale facts must be cleared
    -- before any airborne frame can hit the engine.
    local SafeLanding = require("safelanding")
    SafeLanding.clearAllFacts()
    -- A roll abandoned at main-menu time (player detached mid-roll) must not
    -- resume on the freshly loaded player.
    SafeLanding.resetRollState()

    local config = require("config")
    config.syncSettings()

    local LynxPaw = require("lynxpaw")
    LynxPaw.initHashes()
    LynxPaw.equipped = LynxPaw.checkEquipped()
    pcall(LynxPaw.setupStats)
    pcall(LynxPaw.updateDescriptions)

    -- Seed CET hotkey binding cache so the first fall after load uses the
    -- correct branch (Phases.update refreshes this every 2s thereafter).
    local input = require("input")
    pcall(function()
        input.hotkeyBound.reverseHang = IsBound("OLP_ReverseHang")
        input.hotkeyBound.dismount    = IsBound("OLP_DismountWall")
        input.hotkeyBound.safeRoll    = IsBound("OLP_SafeLandingRoll")
    end)
    -- Never start a session with a stale sprint latch (a BUTTON_RELEASED
    -- missed across a reload would otherwise stick until the next press).
    input.sprintHeldKBM  = false
    input.sprintKeyHeld  = false
    input.pressingSprint = false

    self._config = config
    self._Helpers = Helpers
    self._LynxPaw = LynxPaw
    self._Kerenzikov = require("kerenzikov")
    self._Phases = require("phases")
    self._Debug = require("debug")
    self._input = require("input")
    self._camera = state.camera
    self._wallState = wallState
    self._ShiftCompat = require("shiftcompat")

    self.loaded = true

    -- Log Shinobi skill level for stamina scaling verification
    local ok, shinobiLevel = pcall(function()
        local sys = Game.GetScriptableSystemsContainer():Get("OverclockedLynxPaws.WallRunSettings")
        return sys:GetShinobiLevel()
    end)
    if ok and shinobiLevel then
        Helpers.logDebug("[OLP] Shinobi level: " .. tostring(shinobiLevel))
    else
        Helpers.logDebug("[OLP] ERROR: Could not read Shinobi level")
    end


end

return OverclockedLynxPaws:New()
