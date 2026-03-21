use std::path::Path;
use std::time::Duration;

use harness::infra::blocks::{BlockError, ComposeOrchestrator};
use harness::infra::exec::CommandResult;

/// `up` followed by `down` completes without error.
///
/// # Panics
/// Panics if compose up or down fails.
pub fn contract_up_then_down_succeeds(
    orchestrator: &dyn ComposeOrchestrator,
    compose_file: &Path,
    project_name: &str,
) {
    let up_result = orchestrator
        .up(compose_file, project_name, Duration::from_secs(60))
        .expect("compose up should succeed");
    assert_eq!(up_result.returncode, 0);

    let down_result = orchestrator
        .down(compose_file, project_name)
        .expect("compose down should succeed");
    assert_eq!(down_result.returncode, 0);
}

/// `down_project` succeeds even when no matching project is running.
///
/// # Errors
/// Returns `BlockError` if the orchestrator rejects the down call.
pub fn contract_down_project_is_idempotent(
    orchestrator: &dyn ComposeOrchestrator,
) -> Result<CommandResult, BlockError> {
    orchestrator.down_project("nonexistent-contract-test-project")
}

#[cfg(test)]
mod tests;
