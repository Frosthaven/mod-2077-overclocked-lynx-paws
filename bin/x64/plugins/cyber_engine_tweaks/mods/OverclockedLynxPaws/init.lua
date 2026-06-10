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
            -- KBM hold-to-sprint fallback. The authoritative sprint state (incl.
            -- controller Toggle Sprint, which only taps here) comes from the
            -- redscript wr_sprint_held fact, combined in onUpdate below.
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
                camera.pendingMouseDeltaX = camera.pendingMouseDeltaX + action:GetValue(action)
            elseif name == "CameraMouseY" then
                camera.pendingMouseDeltaY = camera.pendingMouseDeltaY + action:GetValue(action)
            elseif name == "right_stick_x" then
                camera.rightStickX = action:GetValue(action)
            elseif name == "right_stick_y" then
                camera.rightStickY = action:GetValue(action)
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
    end)

    registerForEvent("onShutdown", function()
        if self._LynxPaw then self._LynxPaw.cleanupCrouchSpeed() end
        if self._wallState and self._wallState.player and self._wallState.phase ~= "IDLE" then
            if self._Kerenzikov then self._Kerenzikov.deactivate() end
            if self._Helpers then self._Helpers.applyCameraRoll(0) end
        end
        -- Restore camera offset in case shutdown lands during a safe roll
        if self._wallState and self._wallState.player then
            pcall(function()
                local camComp = self._wallState.player:GetFPPCameraComponent()
                if camComp then camComp:SetLocalPosition(Vector4.new(0, 0, 0, 0)) end
            end)
        end
        if self._Helpers then self._Helpers.endWallYSensitivity() end
        -- Clear mod facts so a CET reload mid-flight can't leave the Redscript
        -- hooks reading stale state (e.g. wr_safe_land = 1 forever).
        local ok, SafeLanding = pcall(require, "safelanding")
        if ok and SafeLanding and SafeLanding.clearAllFacts then
            SafeLanding.clearAllFacts()
        end
        if self._wallState then self._wallState.player = nil end
        self.loaded = false
    end)

    registerForEvent("onUpdate", function(delta)
        if self.loaded and self._Phases then
            -- Effective sprint-held = KBM hold OR the redscript-bridged real sprint
            -- intent (covers controller Toggle Sprint, which the OnAction handler
            -- can't see as "held"). Must run before Phases.update consumes it.
            local sprintHeld = self._input.sprintHeldKBM
            if not sprintHeld then
                local qs = Game.GetQuestsSystem()
                if qs and qs:GetFact(CName.new("wr_sprint_held")) > 0 then
                    sprintHeld = true
                end
            end
            self._input.pressingSprint = sprintHeld

            self._Phases.update(delta, self._config.syncSettings, self._LynxPaw)
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

    self._config = config
    self._Helpers = Helpers
    self._LynxPaw = LynxPaw
    self._Kerenzikov = require("kerenzikov")
    self._Phases = require("phases")
    self._Debug = require("debug")
    self._input = require("input")
    self._camera = state.camera
    self._wallState = wallState

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
