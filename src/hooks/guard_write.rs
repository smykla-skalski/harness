use std::path::Path;

use crate::create::{can_write, suite_create_path_allowed};
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use harness_kernel::errors::{CliError, HookMessage};

use super::normalize_path;

/// Execute the guard-write hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    let paths = ctx.write_paths();
    if paths.is_empty() {
        return Ok(HookResult::allow());
    }
    super::dispatch_by_skill(
        ctx,
        |_ctx| Ok(HookResult::allow()),
        |ctx| Ok(guard_suite_create(ctx, &paths)),
    )
}

fn guard_suite_create(ctx: &HookContext, paths: &[&Path]) -> HookResult {
    let Some(state) = &ctx.create_state else {
        return HookResult::allow();
    };
    let suite_dir = state.suite_path();
    let sd_norm = suite_dir.as_ref().map(|sd| normalize_path(sd));
    let has_suite_output = sd_norm
        .as_ref()
        .is_some_and(|sdn| paths.iter().any(|p| normalize_path(p).starts_with(sdn)));
    if !has_suite_output {
        return HookResult::allow();
    }
    // Validate paths are within the suite:create surface.
    if let Some(ref sdn) = sd_norm {
        for raw_path in paths {
            let norm = normalize_path(raw_path);
            if !norm.starts_with(sdn) {
                continue;
            }
            if !suite_create_path_allowed(&norm, sdn) {
                return HookMessage::write_outside_suite(raw_path.display().to_string())
                    .into_result();
            }
        }
    }
    // Check if writing is allowed in the current phase.
    if let Err(reason) = can_write(state) {
        return HookMessage::approval_required("write suite files", reason).into_result();
    }
    HookResult::allow()
}
