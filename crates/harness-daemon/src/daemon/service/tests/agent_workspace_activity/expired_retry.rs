use harness_kernel::errors::CliError;
use harness_protocol::daemon::activity::AgentWorkspaceSignalAckRequest;

use super::*;
use crate::daemon::protocol::{CodexRunSnapshot, CodexSteerRequest};
use crate::daemon::service::wake_route::CodexWake;

struct ForbiddenCodexWake;

impl CodexWake for ForbiddenCodexWake {
    fn steer(
        &self,
        _run_id: &str,
        _request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        panic!("an expired signal must not wake its managed agent")
    }
}

#[test]
fn expired_signal_retry_settles_without_recreating_runtime_delivery() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(assert_expired_retry_settles(project));
            },
        );
    });
}

#[test]
fn prepared_terminal_acknowledgments_survive_expired_retry() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let fixture = seed_workspace_activity_member(project).await;
                    route_through_forbidden_wake(&fixture).await;
                    assert_prepared_terminal_survives_expiry(
                        project,
                        &fixture,
                        AckResult::Rejected,
                        "prepared-expired-rejected",
                    )
                    .await;
                    assert_prepared_terminal_survives_expiry(
                        project,
                        &fixture,
                        AckResult::Deferred,
                        "prepared-expired-deferred",
                    )
                    .await;
                });
            },
        );
    });
}

#[test]
fn public_accepted_acknowledgment_normalizes_after_expiry() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(assert_public_accepted_acknowledgment_expires(project));
            },
        );
    });
}

async fn assert_public_accepted_acknowledgment_expires(project: &std::path::Path) {
    let fixture = seed_workspace_activity_member(project).await;
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "expired-public-ack-client".into(),
            idempotency_key: "expired-public-ack-1".into(),
            command: "expired-public-ack".into(),
            message: "Normalize a late accepted acknowledgment".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send signal before late public acknowledgment");
    expire_durable_signal(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
    )
    .await;

    let acknowledged = acknowledge_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &AgentWorkspaceSignalAckRequest {
            result: AckResult::Accepted,
            details: Some("accepted after expiry".into()),
        },
    )
    .await
    .expect("acknowledge expired signal through public mutation");
    assert_eq!(acknowledged.status, SessionSignalStatus::Expired);
    assert_eq!(
        acknowledged
            .acknowledgment
            .expect("durable expired acknowledgment")
            .result,
        AckResult::Expired
    );

    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let runtime_ack = runtime::signal::read_acknowledgments(&signal_dir)
        .expect("read normalized runtime acknowledgment")
        .into_iter()
        .find(|acknowledgment| acknowledgment.signal_id == sent.signal.signal_id)
        .expect("normalized runtime acknowledgment");
    assert_eq!(runtime_ack.result, AckResult::Expired);
    assert!(
        runtime::signal::read_pending_signals(&signal_dir)
            .expect("read runtime queue after normalized acknowledgment")
            .iter()
            .all(|signal| signal.signal_id != sent.signal.signal_id)
    );
}

async fn route_through_forbidden_wake(fixture: &WorkspaceActivityFixture) {
    sqlx::query(
        "UPDATE agent_workspace_members
         SET managed_agent_kind = 'codex', managed_agent_id = 'forbidden-expired-wake'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .execute(fixture.db.pool())
    .await
    .expect("route durable member through forbidden Codex wake");
}

async fn assert_prepared_terminal_survives_expiry(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
    result: AckResult,
    operation: &str,
) {
    let request = AgentWorkspaceSignalSendRequest {
        actor: "prepared-expiry-client".into(),
        idempotency_key: operation.into(),
        command: operation.into(),
        message: "Preserve the runtime's first terminal decision".into(),
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
    .expect("send signal before prepared terminal acknowledgment");
    let pending_path = write_prepared_terminal(project, fixture.session_id, &sent.signal, result);
    expire_durable_signal(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
    )
    .await;

    for attempt in 0..2 {
        let settled = send_agent_workspace_signal_async(
            &fixture.db,
            &fixture.workspace_id,
            &fixture.member_id,
            &request,
            WakeDispatch::none().with_codex(Some(&ForbiddenCodexWake)),
        )
        .await
        .unwrap_or_else(|error| panic!("settle prepared terminal retry {attempt}: {error}"));
        assert_eq!(settled.status, SessionSignalStatus::from_ack_result(result));
        assert_eq!(
            settled.acknowledgment.as_ref().map(|ack| ack.result),
            Some(result)
        );
        assert!(!pending_path.exists(), "settled payload must stay moved");
    }
}

fn write_prepared_terminal(
    project: &std::path::Path,
    session_id: &str,
    signal: &runtime::signal::Signal,
    result: AckResult,
) -> std::path::PathBuf {
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let acknowledged_dir = runtime::signal::acknowledged_dir(&signal_dir);
    std::fs::create_dir_all(&acknowledged_dir).expect("create acknowledgment directory");
    let acknowledgment = SignalAck {
        signal_id: signal.signal_id.clone(),
        acknowledged_at: "2026-08-06T12:45:00Z".into(),
        result,
        agent: "workspace-activity-worker".into(),
        session_id: session_id.to_string(),
        details: Some("runtime decision before durable expiry".into()),
    };
    std::fs::write(
        acknowledged_dir.join(format!("{}.ack.json", signal.signal_id)),
        serde_json::to_string_pretty(&acknowledgment)
            .expect("serialize prepared terminal acknowledgment"),
    )
    .expect("write prepared terminal acknowledgment");
    runtime::signal::pending_dir(&signal_dir).join(format!("{}.json", signal.signal_id))
}

async fn expire_durable_signal(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
) {
    sqlx::query(
        "UPDATE agent_workspace_signals
         SET signal_json = json_set(signal_json, '$.expires_at', '2000-01-01T00:00:00Z')
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(signal_id)
    .execute(db.pool())
    .await
    .expect("expire durable signal with prepared terminal acknowledgment");
}

async fn assert_expired_retry_settles(project: &std::path::Path) {
    let fixture = seed_workspace_activity_member(project).await;
    route_through_forbidden_wake(&fixture).await;
    let request = AgentWorkspaceSignalSendRequest {
        actor: "expired-retry-client".into(),
        idempotency_key: "expired-retry-1".into(),
        command: "expired-retry".into(),
        message: "Do not revive expired work".into(),
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
    .expect("send signal before expiry");
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let pending_path =
        runtime::signal::pending_dir(&signal_dir).join(format!("{}.json", sent.signal.signal_id));
    std::fs::remove_file(&pending_path).expect("simulate missing runtime payload after expiry");
    sqlx::query(
        "UPDATE agent_workspace_signals
         SET signal_json = json_set(signal_json, '$.expires_at', '2000-01-01T00:00:00Z')
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .bind(&sent.signal.signal_id)
    .execute(fixture.db.pool())
    .await
    .expect("expire durable signal");

    let settled = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none().with_codex(Some(&ForbiddenCodexWake)),
    )
    .await
    .expect("settle expired retry");
    assert_eq!(settled.status, SessionSignalStatus::Expired);
    assert_eq!(
        settled.acknowledgment.expect("durable expiry").result,
        AckResult::Expired
    );
    assert!(
        !pending_path.exists(),
        "expired payload must not be recreated"
    );
}
