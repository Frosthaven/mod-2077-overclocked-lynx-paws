module OverclockedLynxPaws

// Block climb state entry when wall running mod is active
@wrapMethod(ClimbDecisions)
protected func EnterCondition(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_wall_active") > 0 {
            return false;
        }
    }
    return wrappedMethod(stateContext, scriptInterface);
}

// Block vault state entry when wall running mod is active
@wrapMethod(VaultDecisions)
protected func EnterCondition(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_wall_active") > 0 {
            return false;
        }
    }
    return wrappedMethod(stateContext, scriptInterface);
}

// Block double jump (Reinforced Tendons) when wall running mod is active
@wrapMethod(DoubleJumpEvents)
public func OnEnter(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_wall_active") > 0 {
            return;
        }
    }
    wrappedMethod(stateContext, scriptInterface);
}

// Block charge jump (Fortified Ankles) when wall running mod is active
@wrapMethod(ChargeJumpEvents)
public func OnEnter(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_wall_active") > 0 {
            return;
        }
    }
    wrappedMethod(stateContext, scriptInterface);
}

// Block slide state entry during safe roll
@wrapMethod(SlideDecisions)
protected func EnterCondition(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_safe_roll") > 0 {
            return false;
        }
    }
    return wrappedMethod(stateContext, scriptInterface);
}

// ── Force uncrouch: clear CrouchToggled when signalled by Lua via wr_uncrouch fact ──
// Hooked on CrouchEvents.OnUpdate so it runs every frame while crouched.

@wrapMethod(CrouchEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_uncrouch") > 0 {
            stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
            GameInstance.GetQuestsSystem(player.GetGame()).SetFact(n"wr_uncrouch", 0);
        }
    }
    wrappedMethod(timeDelta, stateContext, scriptInterface);
}

// ── Fallback uncrouch: also clear CrouchToggled from Stand state ──
// CrouchEvents.OnUpdate only runs while in Crouch state. If ForceCrouch removal
// transitions the player out before the hook fires, this catches it.

@wrapMethod(StandEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_uncrouch") > 0 {
            stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
            GameInstance.GetQuestsSystem(player.GetGame()).SetFact(n"wr_uncrouch", 0);
        }
    }
    wrappedMethod(timeDelta, stateContext, scriptInterface);
}

// ── Safe Landing: downgrade hard/death landings to regular when crouch buffer is active ──

@wrapMethod(LocomotionAirEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(timeDelta, stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if !IsDefined(player) {
        return;
    }

    if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_safe_land") <= 0 {
        return;
    }

    // Check if the base method set a dangerous landing type
    let landingType = stateContext.GetIntParameter(n"LandingType", true);
    let hardType = EnumInt(LandingType.Hard);
    let veryHardType = EnumInt(LandingType.VeryHard);
    let deathType = EnumInt(LandingType.Death);

    let shouldOverride = false;
    if landingType == hardType || landingType == veryHardType {
        shouldOverride = true;
    }
    if landingType == deathType {
        let settings = GameInstance.GetScriptableSystemsContainer(player.GetGame()).Get(n"OverclockedLynxPaws.WallRunSettings") as WallRunSettings;
        if IsDefined(settings) && settings.safeLandAnyHeight {
            shouldOverride = true;
        }
    }

    if shouldOverride {
        // Downgrade to regular landing — no damage, no lock, no screen effects
        stateContext.SetPermanentIntParameter(n"LandingType", EnumInt(LandingType.Regular), true);
        stateContext.SetPermanentFloatParameter(n"ImpactSpeed", 0.00, true);

        let landingAnimFeature = new AnimFeature_Landing();
        landingAnimFeature.impactSpeed = 0.00;
        landingAnimFeature.type = EnumInt(LandingType.Regular);
        scriptInterface.SetAnimationParameterFeature(n"Landing", landingAnimFeature);

        // Clear fall blackboard state
        this.SetBlackboardIntVariable(scriptInterface, GetAllBlackboardDefs().PlayerStateMachine.Fall, EnumInt(gamePSMFallStates.RegularFall));
        this.SetBlackboardIntVariable(scriptInterface, GetAllBlackboardDefs().PlayerStateMachine.Landing, 0);
    }
}
