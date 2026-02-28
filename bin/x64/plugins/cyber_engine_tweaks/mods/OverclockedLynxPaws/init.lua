--[[
    Overclocked Lynx Paws - Cyberpunk 2077 CET Mod
    Implements wall running using impulse-based velocity correction for movement
    (preserves full mouse control), and FPP camera component for roll effects.
]]

OverclockedLynxPaws = { loaded = false }

function OverclockedLynxPaws:New()
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

        Observe("PlayerPuppet", "OnAction", function(_, action)
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
                if atype == "BUTTON_PRESSED" then
                    input.crouchJustPressed = true
                end
            end
            if name == "Back" then
                if atype == "BUTTON_PRESSED" then
                    input.backJustPressed = true
                    input.pressingBack = true
                elseif atype == "BUTTON_RELEASED" then
                    input.pressingBack = false
                end
            end
            if name == "Sprint" or name == "ToggleSprint" then
                if atype == "BUTTON_PRESSED" then
                    input.pressingSprint = true
                elseif atype == "BUTTON_RELEASED" then
                    input.pressingSprint = false
                end
            end
            -- Capture horizontal aim input for manual yaw tracking
            if name == "CameraMouseX" then
                camera.pendingMouseDeltaX = camera.pendingMouseDeltaX + action:GetValue(action)
            elseif name == "right_stick_x" then
                camera.rightStickX = action:GetValue(action)
            end
        end)

        -- Hook game climb/vault: trigger our ledge mount during wall phases
        local WallDetect = require("walldetect")
        local function onClimbOrVault()
            if wallState.phase == "IDLE" or wallState.phase == "LEDGE_MOUNTING" then return end
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
        if self._wallState then self._wallState.player = nil end
        self.loaded = false
    end)

    registerForEvent("onUpdate", function(delta)
        if self.loaded and self._Phases then
            self._Phases.update(delta, self._config.syncSettings, self._LynxPaw)
            self._input.jumpJustPressed = false
            self._input.crouchJustPressed = false
            self._input.backJustPressed = false
            self._camera.pendingMouseDeltaX = 0
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

    local config = require("config")
    config.syncSettings()

    local LynxPaw = require("lynxpaw")
    LynxPaw.initHashes()
    LynxPaw.equipped = LynxPaw.checkEquipped()
    pcall(LynxPaw.setupStats)
    pcall(LynxPaw.updateDescriptions)

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
