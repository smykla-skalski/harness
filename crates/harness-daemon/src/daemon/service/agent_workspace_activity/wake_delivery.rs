use std::path::PathBuf;

use harness_agents::runtime;
use harness_agents::runtime::signal::Signal;
use harness_daemon_db_queries::AgentWorkspaceSignalTarget;
use harness_kernel::errors::CliError;

use super::super::signals::build_active_signal_prompt;
use super::super::wake_route::WakeDispatch;
use super::runtime_delivery::{runtime_orchestration_session_id, runtime_signal_session_id};
use crate::daemon::agent_acp::AcpWakePrompt;
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::protocol::CodexSteerRequest;

pub(super) async fn wake_managed_agent(
    db: &AsyncDaemonDbHandle,
    daemon_id: &str,
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
    dispatch: WakeDispatch<'_>,
) -> Result<(), CliError> {
    let Some(runtime) = runtime::runtime_for_name(&target.runtime) else {
        return Ok(());
    };
    let route_available = match target.managed_agent_kind.as_str() {
        "tui" => dispatch.agent_tui.is_some(),
        "acp" => dispatch.acp_agent.is_some(),
        "codex" => dispatch.codex.is_some(),
        _ => false,
    };
    if !route_available {
        return Ok(());
    }
    let claimed_at = harness_workspace::workspace::utc_now();
    if !db
        .claim_agent_workspace_signal_wake(
            daemon_id,
            &target.workspace_id,
            &target.member_id,
            &signal.signal_id,
            &claimed_at,
        )
        .await?
    {
        return Ok(());
    }
    let prompt = build_active_signal_prompt(signal);
    let delivered = match target.managed_agent_kind.as_str() {
        "tui" => wake_tui(target, &prompt, dispatch),
        "acp" => wake_acp(target, signal, &prompt, runtime, dispatch),
        "codex" => wake_codex(target, &prompt, dispatch),
        _ => false,
    };
    if !delivered {
        db.release_agent_workspace_signal_wake(
            daemon_id,
            &target.workspace_id,
            &target.member_id,
            &signal.signal_id,
            &claimed_at,
        )
        .await?;
    }
    Ok(())
}

fn wake_tui(target: &AgentWorkspaceSignalTarget, prompt: &str, dispatch: WakeDispatch<'_>) -> bool {
    let Some(manager) = dispatch.agent_tui else {
        return false;
    };
    match manager.prompt_tui(&target.managed_agent_id, prompt) {
        Ok(delivered) => delivered,
        Err(error) => {
            tracing::warn!(%error, member_id = target.member_id, "durable signal TUI wake failed");
            false
        }
    }
}

fn wake_acp(
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
    prompt: &str,
    runtime: &'static dyn runtime::AgentRuntime,
    dispatch: WakeDispatch<'_>,
) -> bool {
    let Some(manager) = dispatch.acp_agent else {
        return false;
    };
    let signal_session_id = runtime_signal_session_id(target);
    manager.dispatch_wake_prompt(
        runtime,
        AcpWakePrompt {
            acp_id: target.managed_agent_id.clone(),
            orchestration_session_id: runtime_orchestration_session_id(target),
            signal_session_id: signal_session_id.clone(),
            signal_dir: runtime.signal_dir(
                PathBuf::from(&target.project_dir).as_path(),
                &signal_session_id,
            ),
            project_dir: PathBuf::from(&target.project_dir),
            prompt: prompt.to_string(),
            signal_id: signal.signal_id.clone(),
            signal_expires_at: signal.expires_at.clone(),
            agent_id: target.member_id.clone(),
            workspace_id: Some(target.workspace_id.clone()),
            member_id: Some(target.member_id.clone()),
        },
    )
}

fn wake_codex(
    target: &AgentWorkspaceSignalTarget,
    prompt: &str,
    dispatch: WakeDispatch<'_>,
) -> bool {
    let Some(controller) = dispatch.codex else {
        return false;
    };
    match controller.steer(
        &target.managed_agent_id,
        &CodexSteerRequest {
            prompt: prompt.to_string(),
        },
    ) {
        Ok(_) => true,
        Err(error) => {
            tracing::warn!(%error, member_id = target.member_id, "durable signal Codex wake failed");
            false
        }
    }
}
