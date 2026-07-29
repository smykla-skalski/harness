use std::path::Path;
use std::time::{Duration, Instant};

use tempfile::TempDir;

use super::{OpenRouterAgentTurnRuntime, openrouter_start_request};
use crate::agents::acp::catalog::{
    self, AcpAgentDescriptor, AcpSessionConfiguration, AcpSpawnConfiguration,
};
use crate::agents::turn::{
    AgentTurnFailureCategory, AgentTurnId, AgentTurnRuntime, AgentTurnStatus,
    ValidatedAgentTurnRequest,
};
use crate::daemon::agent_acp::manager::AcpAgentManagerHandle;
use crate::daemon::agent_acp::manager::test_support::{
    seeded_manager, write_prompt_delaying_acp_agent, write_reporting_acp_agent,
};
use crate::daemon::agent_acp::{AcpAgentSnapshot, AcpAgentStartRequest};
use crate::session::types::SessionRole;

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";
const POLL_DEADLINE: Duration = Duration::from_secs(30);

fn openrouter_descriptor(command: &Path) -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "openrouter".to_string(),
        display_name: "Fake OpenRouter".to_string(),
        capabilities: Vec::new(),
        launch_command: command.display().to_string(),
        launch_args: Vec::new(),
        env_passthrough: Vec::new(),
        spawn_configuration: AcpSpawnConfiguration::default(),
        model_catalog: None,
        install_hint: None,
        session_configuration: AcpSessionConfiguration::default(),
        doctor_probe: catalog::DoctorProbe {
            command: command.display().to_string(),
            args: Vec::new(),
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
        bundled_with_harness: false,
    }
}

fn start_fake_turn(
    manager: &AcpAgentManagerHandle,
    project_dir: &Path,
    command: &Path,
) -> AcpAgentSnapshot {
    let request = AcpAgentStartRequest {
        agent: "openrouter".to_string(),
        prompt: Some("Review the pull request".to_string()),
        project_dir: Some(project_dir.display().to_string()),
        ..AcpAgentStartRequest::default()
    };
    let descriptor = openrouter_descriptor(command);
    // The "openrouter" spawn path requires a per-spawn key file; the fake shim
    // ignores its args, so any non-empty token drives the deterministic script.
    manager
        .start_descriptor_with_pooling_and_openrouter_token(
            SESSION_ID,
            &request,
            &descriptor,
            false,
            Some("sk-test"),
        )
        .expect("start fake OpenRouter turn")
}

async fn poll_until_terminal(
    runtime: &OpenRouterAgentTurnRuntime,
    id: &AgentTurnId,
) -> AgentTurnStatus {
    let deadline = Instant::now() + POLL_DEADLINE;
    loop {
        let status = runtime.status(id).await.expect("read turn status");
        if status.is_terminal() {
            return status;
        }
        assert!(
            Instant::now() < deadline,
            "turn never reached a terminal state"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[test]
fn start_request_targets_a_fresh_openrouter_report_turn() {
    let request = ValidatedAgentTurnRequest {
        prompt: "Review the pull request".to_string(),
        requested_model: Some("anthropic/claude-sonnet-4-6".to_string()),
        pull_request: None,
    };

    let start = openrouter_start_request(&request);

    assert_eq!(start.agent, "openrouter");
    assert_eq!(start.role, SessionRole::Worker);
    assert_eq!(start.name.as_deref(), Some("OpenRouter report turn"));
    assert_eq!(start.prompt.as_deref(), Some("Review the pull request"));
    assert_eq!(start.model.as_deref(), Some("anthropic/claude-sonnet-4-6"));
    assert!(
        start.resume_disabled,
        "a report turn must open a fresh session, never resume a prior transcript"
    );
    assert!(start.endpoint.is_none());
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn completed_report_turn_surfaces_its_report() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    let script = temp.path().join("openrouter-agent.sh");
    write_reporting_acp_agent(&script, "PR looks good; approving.", "end_turn");
    let manager = seeded_manager();
    let snapshot = start_fake_turn(&manager, temp.path(), &script);
    let runtime = OpenRouterAgentTurnRuntime::new(manager.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.acp_id).expect("correlation id");

    assert_eq!(runtime.runtime(), "openrouter");
    assert_eq!(
        poll_until_terminal(&runtime, &id).await,
        AgentTurnStatus::Completed
    );

    let result = runtime
        .result(&id)
        .await
        .expect("read result")
        .expect("completed turn carries a result");
    assert_eq!(result.correlation_id, id);
    assert_eq!(result.report, "PR looks good; approving.");
    assert_eq!(result.stop_reason, "end_turn");
    assert!(
        runtime.failure(&id).await.expect("read failure").is_none(),
        "a completed turn has no failure"
    );

    manager.stop(id.as_str()).expect("stop");
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn refused_turn_reports_a_provider_rejection() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    let script = temp.path().join("openrouter-agent.sh");
    write_reporting_acp_agent(&script, "I can't help with that.", "refusal");
    let manager = seeded_manager();
    let snapshot = start_fake_turn(&manager, temp.path(), &script);
    let runtime = OpenRouterAgentTurnRuntime::new(manager.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.acp_id).expect("correlation id");

    assert_eq!(
        poll_until_terminal(&runtime, &id).await,
        AgentTurnStatus::Failed
    );
    assert!(
        runtime.result(&id).await.expect("read result").is_none(),
        "a refused turn produces no result"
    );
    let failure = runtime
        .failure(&id)
        .await
        .expect("read failure")
        .expect("refused turn carries a failure");
    assert_eq!(failure.category, AgentTurnFailureCategory::ProviderRejected);

    manager.stop(id.as_str()).expect("stop");
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn cancel_stops_a_running_turn() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    let script = temp.path().join("openrouter-agent.sh");
    // The prompt stays in flight long enough for cancel to race a running
    // turn, but short enough that teardown does not wait on a long sleep.
    write_prompt_delaying_acp_agent(&script, 2.0);
    let manager = seeded_manager();
    let snapshot = start_fake_turn(&manager, temp.path(), &script);
    let runtime = OpenRouterAgentTurnRuntime::new(manager.clone(), SESSION_ID);
    let id = AgentTurnId::new(snapshot.acp_id).expect("correlation id");

    assert_eq!(
        runtime.cancel(&id).await.expect("cancel turn"),
        AgentTurnStatus::Cancelled
    );
    assert_eq!(
        runtime.status(&id).await.expect("status after cancel"),
        AgentTurnStatus::Cancelled
    );
    let failure = runtime
        .failure(&id)
        .await
        .expect("read failure")
        .expect("cancelled turn carries a failure");
    assert_eq!(failure.category, AgentTurnFailureCategory::Cancelled);
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(unix)]
async fn a_turn_from_another_session_is_denied() {
    let Ok(temp) = TempDir::new() else {
        unreachable!();
    };
    let script = temp.path().join("openrouter-agent.sh");
    write_reporting_acp_agent(&script, "done", "end_turn");
    let manager = seeded_manager();
    let snapshot = start_fake_turn(&manager, temp.path(), &script);
    let runtime =
        OpenRouterAgentTurnRuntime::new(manager.clone(), "00b4a39f-719e-5418-abe8-eb3ab6ea614d");
    let id = AgentTurnId::new(snapshot.acp_id).expect("correlation id");

    let error = runtime
        .status(&id)
        .await
        .expect_err("a turn owned by another session must be refused");
    assert!(
        error.to_string().contains("does not belong to session"),
        "unexpected error: {error}"
    );

    manager.stop(id.as_str()).expect("stop");
}
