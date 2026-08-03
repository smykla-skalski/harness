use crate::agents::runtime::{AgentRuntime, InitialPromptDelivery, runtime_for_name};
use crate::daemon::agent_tui::{AgentTuiSnapshot, AgentTuiStatus};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::types::AgentTuiStartSpec;

pub(super) fn ensure_same_agent_tui_launch(
    active: &AgentTuiStartSpec,
    requested: &AgentTuiStartSpec,
) -> Result<(), CliError> {
    if active == requested {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "terminal agent '{}' already belongs to a different host-bridge launch",
        requested.tui_id
    ))
    .into())
}

pub(super) fn ensure_agent_tui_running(snapshot: &AgentTuiSnapshot) -> Result<(), CliError> {
    if matches!(
        snapshot.status,
        AgentTuiStatus::Starting | AgentTuiStatus::Running
    ) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "terminal agent '{}' has already completed in the host bridge",
        snapshot.tui_id
    ))
    .into())
}

pub(super) fn bridge_deferred_auto_join(runtime: &str, prompt: Option<String>) -> Option<String> {
    let delivery = runtime_for_name(runtime).map_or(
        InitialPromptDelivery::PtySend,
        AgentRuntime::initial_prompt_delivery,
    );
    match delivery {
        InitialPromptDelivery::PtySend => prompt.filter(|value| !value.is_empty()),
        InitialPromptDelivery::CliPositional | InitialPromptDelivery::CliFlag(_) => None,
    }
}
