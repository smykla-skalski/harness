/// Skill identity for the test runner.
pub const SKILL_RUN: &str = "suite:run";
/// Skill identity for the suite author.
pub const SKILL_NEW: &str = "suite:new";
/// All recognized skill names.
pub const SKILL_NAMES: &[&str] = &[SKILL_RUN, SKILL_NEW];

/// Filesystem-safe names derived from skill identity.
pub mod dirs {
    pub const RUN_STATE_FILE: &str = "suite-run-state.json";
    pub const NEW_WORKSPACE: &str = "suite-new";
    pub const NEW_STATE_FILE: &str = "suite-new-state.json";
}
