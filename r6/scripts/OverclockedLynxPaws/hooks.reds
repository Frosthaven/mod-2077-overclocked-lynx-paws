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
        let qs = GameInstance.GetQuestsSystem(player.GetGame());
        if qs.GetFact(n"wr_uncrouch") > 0 {
            stateContext.SetConditionBoolParameter(n"CrouchToggled", false, true);
            qs.SetFact(n"wr_uncrouch", 0);
        }
    }
    wrappedMethod(timeDelta, stateContext, scriptInterface);
}

// ── Force sprint after safe roll uncrouch ──

@wrapMethod(SprintDecisions)
protected const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
    let player = scriptInterface.executionOwner as PlayerPuppet;
    if IsDefined(player) {
        if GameInstance.GetQuestsSystem(player.GetGame()).GetFact(n"wr_sprint") > 0 {
            GameInstance.GetQuestsSystem(player.GetGame()).SetFact(n"wr_sprint", 0);
            return true;
        }
    }
    return wrappedMethod(stateContext, scriptInterface);
}

// ── Block arm cyberware equip/unequip during wall phases (Cyberware-EX compatibility) ──
// Prevents Cyberware-EX from activating other arm implants (rockets, gorilla arms, monowire)
// when melee is pressed during wall running. Our mantis grab uses direct AnimFeatures instead.

@wrapMethod(EquipmentSystem)
private final func OnEquipmentSystemWeaponManipulationRequest(request: ref<EquipmentSystemWeaponManipulationRequest>) -> Void {
    let owner = request.owner as PlayerPuppet;
    if IsDefined(owner) {
        if GameInstance.GetQuestsSystem(owner.GetGame()).GetFact(n"wr_wall_active") > 0 {
            let action = request.requestType;
            if Equals(action, EquipmentManipulationAction.RequestLeftHandCyberware) || Equals(action, EquipmentManipulationAction.UnequipLeftHandCyberware) {
                return;
            }
        }
    }
    wrappedMethod(request);
}

// ── Safe Landing: downgrade hard/death landings to regular when crouch buffer is active ──

@wrapMethod(LocomotionAirEvents)
protected func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
    wrappedMethod(timeDelta, stateContext, scriptInterface);

    let player = scriptInterface.executionOwner as PlayerPuppet;
    if !IsDefined(player) {
        return;
    }

    // Reset double jump counter when signalled by wall run/climb entry
    let qs = GameInstance.GetQuestsSystem(player.GetGame());
    if qs.GetFact(n"wr_reset_jumps") > 0 {
        stateContext.SetPermanentIntParameter(n"currentNumberOfJumps", 0, true);
        qs.SetFact(n"wr_reset_jumps", 0);
    }

    if qs.GetFact(n"wr_safe_land") <= 0 {
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

        // Confirm to Lua that the landing was successfully downgraded
        qs.SetFact(n"wr_landing_safe", 1);
    }
}
