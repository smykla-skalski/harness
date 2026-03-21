/// Skill identity for the test runner.
pub const SKILL_RUN: &str = "suite:run";
/// Skill identity for the suite:create workflow.
pub const SKILL_CREATE: &str = "suite:create";
/// All recognized skill names.
pub const SKILL_NAMES: &[&str] = &[SKILL_RUN, SKILL_CREATE];

/// Filesystem-safe names derived from skill identity.
pub mod dirs {
    pub const RUN_STATE_FILE: &str = "suite-run-state.json";
    pub const CREATE_WORKSPACE: &str = "suite-create";
    pub const CREATE_STATE_FILE: &str = "suite-create-state.json";
}
