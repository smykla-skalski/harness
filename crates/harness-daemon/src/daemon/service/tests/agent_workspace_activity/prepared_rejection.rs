use super::*;

use harness_kernel::errors::CliError;

use crate::daemon::protocol::{CodexRunSnapshot, CodexSteerRequest};
use crate::daemon::service::wake_route::CodexWake;

struct ForbiddenCodexWake;

impl CodexWake for ForbiddenCodexWake {
    fn steer(
        &self,
        _run_id: &str,
        _request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        panic!("a rejected prepared signal must not wake its agent")
    }
}

#[test]
fn rejected_prepared_signal_retry_settles_without_waking() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(assert_rejected_retry_does_not_wake(project));
            },
        );
    });
}

async fn assert_rejected_retry_does_not_wake(project: &std::path::Path) {
    let fixture = seed_workspace_activity_member(project).await;
    sqlx::query(
        "UPDATE agent_workspace_members
         SET managed_agent_kind = 'codex', managed_agent_id = 'forbidden-codex-wake'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .execute(fixture.db.pool())
    .await
    .expect("route durable member wakes through Codex");
    let request = AgentWorkspaceSignalSendRequest {
        actor: "prepared-rejection-client".into(),
        idempotency_key: "prepared-rejection-1".into(),
        command: "prepared-rejection".into(),
        message: "Never deliver this rejected signal".into(),
        action_hint: None,
    };
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("insert signal before simulated cancellation crash");
    write_prepared_rejection(project, fixture.session_id, &sent.signal);

    let retry = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none().with_codex(Some(&ForbiddenCodexWake)),
    )
    .await
    .expect("settle rejected prepared signal on retry");

    assert_eq!(retry.status, SessionSignalStatus::Rejected);
    assert_eq!(
        retry.acknowledgment.as_ref().map(|ack| ack.result),
        Some(AckResult::Rejected)
    );
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    assert!(
        runtime::signal::read_pending_signals(&signal_dir)
            .expect("read settled runtime queue")
            .iter()
            .all(|signal| signal.signal_id != sent.signal.signal_id)
    );
}

fn write_prepared_rejection(
    project: &std::path::Path,
    session_id: &str,
    signal: &runtime::signal::Signal,
) {
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let acknowledged_dir = runtime::signal::acknowledged_dir(&signal_dir);
    std::fs::create_dir_all(&acknowledged_dir).expect("create acknowledgment directory");
    let acknowledgment = SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: "2026-08-06T12:45:00Z".into(),
        result: AckResult::Rejected,
        agent: "workspace-activity-worker".into(),
        session_id: session_id.to_string(),
        details: Some("cancelled before durable settlement".into()),
    };
    std::fs::write(
        acknowledged_dir.join(format!("{}.ack.json", signal.signal_id)),
        serde_json::to_string_pretty(&acknowledgment).expect("serialize prepared rejection"),
    )
    .expect("write prepared rejection without moving pending payload");
}
