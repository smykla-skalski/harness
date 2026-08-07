use std::path::PathBuf;

use harness_agents::runtime;
use harness_agents::runtime::signal::Signal;
use harness_daemon_db_queries::AgentWorkspaceSignalTarget;

use super::super::signals::build_active_signal_prompt;
use super::super::wake_route::WakeDispatch;
use super::runtime_delivery::{
    release_signal_wake, reserve_signal_wake, runtime_orchestration_session_id,
    runtime_signal_session_id,
};
use crate::daemon::agent_acp::AcpWakePrompt;
use crate::daemon::protocol::CodexSteerRequest;

pub(super) fn wake_managed_agent(
    target: &AgentWorkspaceSignalTarget,
    signal: &Signal,
    dispatch: WakeDispatch<'_>,
) {
    let Some(runtime) = runtime::runtime_for_name(&target.runtime) else {
        return;
    };
    let prompt = build_active_signal_prompt(signal);
    if target.managed_agent_kind == "acp" {
        let _ = wake_acp(target, signal, &prompt, runtime, dispatch);
        return;
    }
    let attempted = match target.managed_agent_kind.as_str() {
        "tui" => dispatch.agent_tui.is_some(),
        "codex" => dispatch.codex.is_some(),
        _ => false,
    };
    if !attempted || !reserve_signal_wake(&signal.signal_id) {
        return;
    }
    let delivered = match target.managed_agent_kind.as_str() {
        "tui" => wake_tui(target, &prompt, dispatch),
        "codex" => wake_codex(target, &prompt, dispatch),
        _ => false,
    };
    if !delivered {
        release_signal_wake(&signal.signal_id);
    }
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
            agent_id: target.member_id.clone(),
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
