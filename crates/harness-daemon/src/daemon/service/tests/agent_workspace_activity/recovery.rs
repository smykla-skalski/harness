use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::AgentWorkspaceSignalAckRequest;

use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus, CodexSteerRequest};
use crate::daemon::service::wake_route::CodexWake;

struct CountingCodexWake {
    calls: AtomicUsize,
    succeeds: bool,
}

impl CountingCodexWake {
    fn failing() -> Self {
        Self {
            calls: AtomicUsize::new(0),
            succeeds: false,
        }
    }

    fn successful() -> Self {
        Self {
            calls: AtomicUsize::new(0),
            succeeds: true,
        }
    }
}

impl CodexWake for CountingCodexWake {
    fn steer(
        &self,
        _run_id: &str,
        _request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.succeeds {
            return Ok(successful_wake_snapshot());
        }
        Err(CliErrorKind::workflow_io("wake probe failed").into())
    }
}

fn successful_wake_snapshot() -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-wake-probe".into(),
        session_id: "workspace-activity-session".into(),
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        session_agent_id: None,
        display_name: None,
        project_dir: "/tmp/workspace-activity".into(),
        thread_id: None,
        turn_id: None,
        mode: CodexRunMode::Report,
        status: CodexRunStatus::Running,
        prompt: "wake probe".into(),
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-08-06T12:00:00Z".into(),
        updated_at: "2026-08-06T12:00:00Z".into(),
        model: None,
        effort: None,
    }
}

#[test]
fn workspace_signal_delivery_scopes_callers_and_repairs_a_stranded_insert() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let fixture = seed_workspace_activity_member(project).await;
                    assert_caller_scoped_operations(&fixture).await;
                    assert_stranded_insert_recovery(project, &fixture).await;
                    assert_pending_retry_rewakes(&fixture).await;
                    assert_response_loss_retry_does_not_rewake(&fixture).await;
                    assert_missing_payload_cancellation(project, &fixture).await;
                    assert_public_acknowledgment_settles_runtime(project, &fixture).await;
                    assert_runtime_first_acknowledgment_converges(project, &fixture).await;
                    assert_concurrent_cancellation_converges(project, &fixture).await;
                });
            },
        );
    });
}

async fn assert_pending_retry_rewakes(fixture: &WorkspaceActivityFixture) {
    sqlx::query(
        "UPDATE agent_workspace_members
         SET managed_agent_kind = 'codex', managed_agent_id = 'codex-wake-probe'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .execute(fixture.db.pool())
    .await
    .expect("route durable member wakes through Codex");
    let request = AgentWorkspaceSignalSendRequest {
        actor: "wake-recovery-client".into(),
        idempotency_key: "wake-recovery-1".into(),
        command: "wake-recovery".into(),
        message: "Recover wake dispatch for the pending signal".into(),
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
    .expect("create pending signal before simulated wake crash");
    let wake = CountingCodexWake::failing();

    send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none().with_codex(Some(&wake)),
    )
    .await
    .expect("retry pending signal wake");
    assert_eq!(wake.calls.load(Ordering::SeqCst), 1);
    let wake_claimed_at = sqlx::query_scalar::<_, Option<String>>(
        "SELECT wake_claimed_at FROM agent_workspace_signals
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .bind(&sent.signal.signal_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load failed wake claim");
    assert!(wake_claimed_at.is_none());
}

async fn assert_response_loss_retry_does_not_rewake(fixture: &WorkspaceActivityFixture) {
    let request = AgentWorkspaceSignalSendRequest {
        actor: "response-loss-client".into(),
        idempotency_key: "response-loss-1".into(),
        command: "response-loss".into(),
        message: "Do not repeat a successful wake after response loss".into(),
        action_hint: None,
    };
    let wake = CountingCodexWake::successful();
    let dispatch = WakeDispatch::none().with_codex(Some(&wake));
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        dispatch,
    )
    .await
    .expect("send signal before simulated response loss");

    send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        dispatch,
    )
    .await
    .expect("retry signal after simulated response loss");
    assert_eq!(wake.calls.load(Ordering::SeqCst), 1);

    sqlx::query(
        "UPDATE agent_workspace_signals SET wake_claimed_at = '2000-01-01T00:00:00Z'
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .bind(&sent.signal.signal_id)
    .execute(fixture.db.pool())
    .await
    .expect("expire durable signal wake claim");
    send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        dispatch,
    )
    .await
    .expect("retry signal after wake claim expiry");
    assert_eq!(wake.calls.load(Ordering::SeqCst), 2);

    cancel_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &AgentWorkspaceSignalCancelRequest {
            actor: "response-loss-client".into(),
        },
    )
    .await
    .expect("settle response-loss wake probe");
}

async fn assert_missing_payload_cancellation(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "missing-payload-client".into(),
            idempotency_key: "missing-payload-cancel-1".into(),
            command: "missing-payload-cancel".into(),
            message: "Cancel after the runtime payload disappears".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send signal before removing runtime payload");
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let pending_path =
        runtime::signal::pending_dir(&signal_dir).join(format!("{}.json", sent.signal.signal_id));
    std::fs::remove_file(&pending_path).expect("remove runtime payload before cancellation");
    sqlx::query(
        "UPDATE agent_workspace_members
         SET runtime_lifecycle = 'unavailable', liveness_status = 'disconnected'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .execute(fixture.db.pool())
    .await
    .expect("make durable member unavailable");

    let cancelled = cancel_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &AgentWorkspaceSignalCancelRequest {
            actor: "missing-payload-client".into(),
        },
    )
    .await
    .expect("cancel unavailable signal with missing runtime payload");
    assert_eq!(cancelled.status, SessionSignalStatus::Rejected);
    assert!(
        runtime::signal::read_acknowledgments(&signal_dir)
            .expect("read reconstructed cancellation acknowledgment")
            .iter()
            .any(|acknowledgment| acknowledgment.signal_id == sent.signal.signal_id)
    );

    sqlx::query(
        "UPDATE agent_workspace_members
         SET runtime_lifecycle = 'unavailable', liveness_status = 'active'
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .execute(fixture.db.pool())
    .await
    .expect("restore durable member addressability");
}

async fn assert_public_acknowledgment_settles_runtime(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "ack-client".into(),
            idempotency_key: "public-ack-1".into(),
            command: "public-ack".into(),
            message: "Acknowledge through the public mutation".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send signal for public acknowledgment");
    let acknowledged = acknowledge_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &AgentWorkspaceSignalAckRequest {
            result: AckResult::Accepted,
            details: Some("accepted through API".into()),
        },
    )
    .await
    .expect("acknowledge signal through public mutation");
    let durable_ack = acknowledged
        .acknowledgment
        .expect("durable public acknowledgment");
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let runtime_ack = runtime::signal::read_acknowledgments(&signal_dir)
        .expect("read public runtime acknowledgment")
        .into_iter()
        .find(|acknowledgment| acknowledgment.signal_id == sent.signal.signal_id)
        .expect("public runtime acknowledgment");
    assert_eq!(durable_ack.acknowledged_at, runtime_ack.acknowledged_at);
    assert_eq!(runtime_ack.agent, "workspace-activity-worker");
    assert_eq!(runtime_ack.session_id, fixture.session_id);
    assert!(
        runtime::signal::read_pending_signals(&signal_dir)
            .expect("read queue after public acknowledgment")
            .iter()
            .all(|signal| signal.signal_id != sent.signal.signal_id)
    );
}

async fn assert_runtime_first_acknowledgment_converges(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "runtime-first-client".into(),
            idempotency_key: "runtime-first-ack-1".into(),
            command: "runtime-first-ack".into(),
            message: "Converge a runtime-first acknowledgment".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send signal for runtime-first acknowledgment");
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    runtime::signal::acknowledge_signal(
        &signal_dir,
        &SignalAck {
            signal_id: sent.signal.signal_id.clone(),
            acknowledged_at: "2026-08-06T12:30:00Z".into(),
            result: AckResult::Accepted,
            agent: "workspace-activity-worker".into(),
            session_id: fixture.session_id.to_string(),
            details: Some("accepted before public retry".into()),
        },
    )
    .expect("write runtime-first acknowledgment");

    let acknowledged = acknowledge_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &AgentWorkspaceSignalAckRequest {
            result: AckResult::Accepted,
            details: Some("accepted before public retry".into()),
        },
    )
    .await
    .expect("converge runtime-first public acknowledgment");
    assert_eq!(
        acknowledged
            .acknowledgment
            .expect("durable runtime-first acknowledgment")
            .acknowledged_at,
        "2026-08-06T12:30:00Z"
    );
}

async fn assert_concurrent_cancellation_converges(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "race-client".into(),
            idempotency_key: "cancel-race-1".into(),
            command: "cancel-race".into(),
            message: "Cancel this signal concurrently".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send signal for concurrent cancellation");
    let request = AgentWorkspaceSignalCancelRequest {
        actor: "race-client".into(),
    };
    let (first, second) = tokio::join!(
        cancel_agent_workspace_signal_async(
            &fixture.db,
            &fixture.workspace_id,
            &fixture.member_id,
            &sent.signal.signal_id,
            &request,
        ),
        cancel_agent_workspace_signal_async(
            &fixture.db,
            &fixture.workspace_id,
            &fixture.member_id,
            &sent.signal.signal_id,
            &request,
        )
    );
    let first = first.expect("first concurrent cancellation");
    let second = second.expect("second concurrent cancellation");
    let first_ack = first.acknowledgment.expect("first durable acknowledgment");
    let second_ack = second
        .acknowledgment
        .expect("second durable acknowledgment");
    assert_eq!(first_ack.acknowledged_at, second_ack.acknowledged_at);

    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let runtime_ack = runtime::signal::read_acknowledgments(&signal_dir)
        .expect("read concurrent cancellation acknowledgment")
        .into_iter()
        .find(|acknowledgment| acknowledgment.signal_id == sent.signal.signal_id)
        .expect("runtime concurrent cancellation acknowledgment");
    assert_eq!(first_ack.acknowledged_at, runtime_ack.acknowledged_at);
}

async fn assert_caller_scoped_operations(fixture: &WorkspaceActivityFixture) {
    let request = AgentWorkspaceSignalSendRequest {
        actor: "remote-client-a".into(),
        idempotency_key: "shared-operation-1".into(),
        command: "continue".into(),
        message: "Continue from durable workspace state".into(),
        action_hint: None,
    };
    let first = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("send first caller operation");
    let second = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "remote-client-b".into(),
            ..request
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send second caller operation with the same local key");

    assert_ne!(first.signal.signal_id, second.signal.signal_id);
}

async fn assert_stranded_insert_recovery(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let request = AgentWorkspaceSignalSendRequest {
        actor: "recovery-client".into(),
        idempotency_key: "stranded-operation-1".into(),
        command: "recover".into(),
        message: "Recover the committed durable signal".into(),
        action_hint: None,
    };
    let stranded = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("commit and deliver durable signal");
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let pending_path = runtime::signal::pending_dir(&signal_dir)
        .join(format!("{}.json", stranded.signal.signal_id));
    std::fs::remove_file(&pending_path).expect("simulate crash before runtime file commit");

    let recovered = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("retry committed signal delivery");
    assert_eq!(recovered.signal.signal_id, stranded.signal.signal_id);
    let pending = runtime::signal::read_pending_signals(&signal_dir)
        .expect("read repaired runtime signal queue");
    assert!(
        pending
            .iter()
            .any(|signal| signal.signal_id == stranded.signal.signal_id)
    );
}
