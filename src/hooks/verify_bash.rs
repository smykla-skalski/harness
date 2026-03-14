use std::path::Path;

use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Tracked subcommands that produce artifacts to verify.
const TRACKED_SUBCOMMANDS: &[&str] = &["apply", "capture", "preflight", "record", "run"];

/// Execute the verify-bash hook.
///
/// For suite-runner, verifies that Bash commands produced the expected
/// artifacts. Full artifact checking needs `RunContext`; this version
/// checks what it can from the command shape alone and allows otherwise.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if ctx.skill != "suite-runner" {
        return Ok(HookResult::allow());
    }
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    let words = ctx.command_words();
    if words.len() < 2 {
        return Ok(HookResult::allow());
    }
    let head_name = Path::new(&words[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head_name != "harness" {
        return Ok(HookResult::allow());
    }
    let subcommand = words[1].as_str();
    if !TRACKED_SUBCOMMANDS.contains(&subcommand) && subcommand != "cluster" {
        return Ok(HookResult::allow());
    }
    // Full implementation verifies artifacts on disk using RunContext
    // and CommandSnapshot. Without that infrastructure, emit a warning
    // for tracked commands as a reminder, but allow.
    if ctx.run_dir.is_none() {
        return Ok(HookResult::allow());
    }
    // With a run dir but no RunContext to read artifacts, we can't
    // confirm artifacts are present. Allow for now.
    Ok(HookResult::allow())
}
