// ── Skill identity (single source of truth) ──────────────────────────
//
// Change the literal inside each macro to rename a skill everywhere.
// The macro approach lets `concat!()` work in const position without
// pulling in `const_format`.

/// Expands to the `suite:run` skill name literal.
macro_rules! skill_run {
    () => {
        "suite:run"
    };
}

/// Expands to the `suite:new` skill name literal.
macro_rules! skill_new {
    () => {
        "suite:new"
    };
}

/// Skill identity for the test runner.
pub const SKILL_RUN: &str = skill_run!();
/// Skill identity for the suite author.
pub const SKILL_NEW: &str = skill_new!();
/// All recognized skill names (for CLI value parsers).
pub const SKILL_NAMES: &[&str] = &[SKILL_RUN, SKILL_NEW];

/// Filesystem-safe names (no colons) derived from skill identity.
pub mod skill_dirs {
    pub const RUN_STATE_FILE: &str = concat!("suite-run", "-state.json");
    pub const NEW_WORKSPACE: &str = "suite-new";
    pub const NEW_STATE_FILE: &str = concat!("suite-new", "-state.json");
}
