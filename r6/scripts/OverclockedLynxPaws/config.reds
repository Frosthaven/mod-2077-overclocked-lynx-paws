module OverclockedLynxPaws

public class WallRunSettings extends ScriptableSystem {

    // ── General ──────────────────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.category.order", "1")
    @runtimeProperty("ModSettings.displayName", "Enable Parkour")
    @runtimeProperty("ModSettings.description", "Master toggle for wall running and safe landing")
    public let enabled: Bool = true;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.category.order", "1")
    @runtimeProperty("ModSettings.displayName", "Require Lynx Paws")
    @runtimeProperty("ModSettings.description", "Wall running and climbing only work when Lynx Paw leg cyberware is equipped")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let requireLynxPaws: Bool = true;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.category.order", "1")
    @runtimeProperty("ModSettings.displayName", "Require Sprint Key")
    @runtimeProperty("ModSettings.description", "Wall run and climb require holding the sprint key")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let requireSprint: Bool = false;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.category.order", "1")
    @runtimeProperty("ModSettings.displayName", "Enable Kerenzikov Support")
    @runtimeProperty("ModSettings.description", "Activate Kerenzikov (if equipped) when aiming down sights during wall run")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let triggerKerenzikov: Bool = true;

    // ── Progression Scaling ─────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Progression Scaling")
    @runtimeProperty("ModSettings.category.order", "2")
    @runtimeProperty("ModSettings.displayName", "Gain Shinobi XP")
    @runtimeProperty("ModSettings.description", "Award Shinobi (Reflexes) skill XP for wall actions")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let gainShinobiSkill: Bool = true;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Progression Scaling")
    @runtimeProperty("ModSettings.category.order", "2")
    @runtimeProperty("ModSettings.displayName", "Enable Stamina Drain")
    @runtimeProperty("ModSettings.description", "Drain stamina for wall actions. Can be reduced by up to 80%")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let drainStamina: Bool = true;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Progression Scaling")
    @runtimeProperty("ModSettings.category.order", "2")
    @runtimeProperty("ModSettings.displayName", "Scale With [on:Shinobi, off:Cyberware]")
    @runtimeProperty("ModSettings.description", "Scale stamina drain cost reduction by Shinobi or cyberware tier (max 80%)")
    @runtimeProperty("ModSettings.dependency", "drainStamina")
    public let staminaScalesShinobi: Bool = true;

    // ── Wall Run ─────────────────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Run")
    @runtimeProperty("ModSettings.category.order", "3")
    @runtimeProperty("ModSettings.displayName", "Wall Run Duration")
    @runtimeProperty("ModSettings.description", "How long you can run along a wall (seconds)")
    @runtimeProperty("ModSettings.step", "0.25")
    @runtimeProperty("ModSettings.min", "0.5")
    @runtimeProperty("ModSettings.max", "5.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let wallRunDuration: Float = 1.5;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Run")
    @runtimeProperty("ModSettings.category.order", "3")
    @runtimeProperty("ModSettings.displayName", "Wall Climb Duration")
    @runtimeProperty("ModSettings.description", "How long you can climb a wall (seconds)")
    @runtimeProperty("ModSettings.step", "0.25")
    @runtimeProperty("ModSettings.min", "0.25")
    @runtimeProperty("ModSettings.max", "5.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let wallClimbDuration: Float = 0.50;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Run")
    @runtimeProperty("ModSettings.category.order", "3")
    @runtimeProperty("ModSettings.displayName", "Wall Slide Duration")
    @runtimeProperty("ModSettings.description", "How long you slide down a wall before dropping (seconds)")
    @runtimeProperty("ModSettings.step", "0.25")
    @runtimeProperty("ModSettings.min", "0.5")
    @runtimeProperty("ModSettings.max", "10.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let wallSlideDuration: Float = 1.5;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Run")
    @runtimeProperty("ModSettings.category.order", "3")
    @runtimeProperty("ModSettings.displayName", "Aim Sensitivity")
    @runtimeProperty("ModSettings.description", "Aim sensitivity multiplier during wall run, climb, and kick")
    @runtimeProperty("ModSettings.step", "0.1")
    @runtimeProperty("ModSettings.min", "0.1")
    @runtimeProperty("ModSettings.max", "3.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let aimSensitivity: Float = 1.0;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Run")
    @runtimeProperty("ModSettings.category.order", "3")
    @runtimeProperty("ModSettings.displayName", "Minimum Wall Run Entry Angle")
    @runtimeProperty("ModSettings.description", "Minimum approach angle for wall running (0 = head-on, 90 = parallel). Approaches below this angle trigger wall climb when looking at the wall.")
    @runtimeProperty("ModSettings.step", "5.0")
    @runtimeProperty("ModSettings.min", "10.0")
    @runtimeProperty("ModSettings.max", "60.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let wallRunEntryAngle: Float = 15.0;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Run")
    @runtimeProperty("ModSettings.category.order", "3")
    @runtimeProperty("ModSettings.displayName", "Camera Tilt")
    @runtimeProperty("ModSettings.description", "Camera roll angle (degrees) while wall running")
    @runtimeProperty("ModSettings.step", "1.0")
    @runtimeProperty("ModSettings.min", "0.0")
    @runtimeProperty("ModSettings.max", "45.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let cameraTilt: Float = 21.0;

    // ── Wall Jump ────────────────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Jump")
    @runtimeProperty("ModSettings.category.order", "4")
    @runtimeProperty("ModSettings.displayName", "Wall Hangtime")
    @runtimeProperty("ModSettings.description", "How long to hold position before kicking off the wall (seconds)")
    @runtimeProperty("ModSettings.step", "0.25")
    @runtimeProperty("ModSettings.min", "0.25")
    @runtimeProperty("ModSettings.max", "10.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let wallKickAimHold: Float = 0.25;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Jump")
    @runtimeProperty("ModSettings.category.order", "4")
    @runtimeProperty("ModSettings.displayName", "Wall Kick Force")
    @runtimeProperty("ModSettings.description", "How fast and far the wall kick launches you")
    @runtimeProperty("ModSettings.step", "0.5")
    @runtimeProperty("ModSettings.min", "5.0")
    @runtimeProperty("ModSettings.max", "40.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let wallKickForce: Float = 12.0;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Jump")
    @runtimeProperty("ModSettings.category.order", "4")
    @runtimeProperty("ModSettings.displayName", "Max Wall Chains")
    @runtimeProperty("ModSettings.description", "How many wall-to-wall chains are allowed per airborne period")
    @runtimeProperty("ModSettings.step", "1")
    @runtimeProperty("ModSettings.min", "0")
    @runtimeProperty("ModSettings.max", "5")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let maxWallChains: Int32 = 2;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Wall Jump")
    @runtimeProperty("ModSettings.category.order", "4")
    @runtimeProperty("ModSettings.displayName", "Chain Bonus Duration")
    @runtimeProperty("ModSettings.description", "Extra wall time (seconds) added when chaining to a new wall")
    @runtimeProperty("ModSettings.step", "0.25")
    @runtimeProperty("ModSettings.min", "0.0")
    @runtimeProperty("ModSettings.max", "3.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let chainBonusDuration: Float = 1.0;

    // ── Safe Landing ──────────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Safe Landing")
    @runtimeProperty("ModSettings.category.order", "5")
    @runtimeProperty("ModSettings.displayName", "Opportunity Window")
    @runtimeProperty("ModSettings.description", "How long before landing you can press crouch to trigger a safe roll landing (seconds)")
    @runtimeProperty("ModSettings.step", "0.1")
    @runtimeProperty("ModSettings.min", "0.0")
    @runtimeProperty("ModSettings.max", "4.0")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let safeLandWindow: Float = 0.30;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Safe Landing")
    @runtimeProperty("ModSettings.category.order", "5")
    @runtimeProperty("ModSettings.displayName", "Survive Any Height")
    @runtimeProperty("ModSettings.description", "Allow safe landing even from normally lethal fall heights")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let safeLandAnyHeight: Bool = false;

    // ── Can't Get Enough? ─────────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Can't Get Enough?")
    @runtimeProperty("ModSettings.category.order", "6")
    @runtimeProperty("ModSettings.displayName", "Unlimited Wall Run")
    @runtimeProperty("ModSettings.description", "Wall run never times out")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let unlimitedWallRun: Bool = false;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Can't Get Enough?")
    @runtimeProperty("ModSettings.category.order", "6")
    @runtimeProperty("ModSettings.displayName", "Unlimited Wall Climb")
    @runtimeProperty("ModSettings.description", "Wall climb never times out")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let unlimitedWallClimb: Bool = false;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Can't Get Enough?")
    @runtimeProperty("ModSettings.category.order", "6")
    @runtimeProperty("ModSettings.displayName", "Unlimited Wall Slide")
    @runtimeProperty("ModSettings.description", "Wall slide never times out")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let unlimitedWallSlide: Bool = false;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Can't Get Enough?")
    @runtimeProperty("ModSettings.category.order", "6")
    @runtimeProperty("ModSettings.displayName", "Unlimited Hangtime")
    @runtimeProperty("ModSettings.description", "Wall hangtime never times out")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let unlimitedHangtime: Bool = false;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Can't Get Enough?")
    @runtimeProperty("ModSettings.category.order", "6")
    @runtimeProperty("ModSettings.displayName", "Unlimited Wall Chains")
    @runtimeProperty("ModSettings.description", "No limit on wall-to-wall chains")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let unlimitedWallChains: Bool = false;

    // ── Debug ─────────────────────────────────────────────────────────────

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Debug")
    @runtimeProperty("ModSettings.category.order", "7")
    @runtimeProperty("ModSettings.displayName", "Debug Overlay")
    @runtimeProperty("ModSettings.description", "Show wall running state info on screen")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let debugEnabled: Bool = false;

    @runtimeProperty("ModSettings.mod", "Overclocked Lynx Paws")
    @runtimeProperty("ModSettings.category", "Debug")
    @runtimeProperty("ModSettings.category.order", "7")
    @runtimeProperty("ModSettings.displayName", "Enable CET Logs")
    @runtimeProperty("ModSettings.description", "Print detailed debug information to the CET console log")
    @runtimeProperty("ModSettings.dependency", "enabled")
    public let cetLogsEnabled: Bool = false;

    // ── Helpers ──────────────────────────────────────────────────────────

    public func GetShinobiLevel() -> Int32 {
        let player = GetPlayer(this.GetGameInstance());
        if !IsDefined(player) { return 0; }
        let pds = GameInstance.GetScriptableSystemsContainer(this.GetGameInstance()).Get(n"PlayerDevelopmentSystem") as PlayerDevelopmentSystem;
        if !IsDefined(pds) { return 0; }
        let data = pds.GetDevelopmentData(player);
        if !IsDefined(data) { return 0; }
        return data.GetProficiencyLevel(gamedataProficiencyType.ReflexesSkill);
    }

    // ── Lifecycle ────────────────────────────────────────────────────────

    private func OnAttach() -> Void {
        ModSettings.RegisterListenerToClass(this);
    }

    private func OnDetach() -> Void {
        ModSettings.UnregisterListenerToClass(this);
    }
}
