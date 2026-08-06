use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::daemon::activity::AgentWorkspaceSignalAckRequest;

use crate::daemon::protocol::{CodexRunSnapshot, CodexSteerRequest};
use crate::daemon::service::wake_route::CodexWake;

struct CountingCodexWake(AtomicUsize);

impl CodexWake for CountingCodexWake {
    fn steer(
        &self,
        _run_id: &str,
        _request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Err(CliErrorKind::workflow_io("wake probe completed").into())
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
                    assert_missing_payload_cancellation(project, &fixture).await;
                    assert_public_acknowledgment_settles_runtime(project, &fixture).await;
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
    send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("create pending signal before simulated wake crash");
    let wake = CountingCodexWake(AtomicUsize::new(0));

    send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none().with_codex(Some(&wake)),
    )
    .await
    .expect("retry pending signal wake");
    assert_eq!(wake.0.load(Ordering::SeqCst), 1);
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
    assert!(
        runtime::signal::read_pending_signals(&signal_dir)
            .expect("read queue after public acknowledgment")
            .iter()
            .all(|signal| signal.signal_id != sent.signal.signal_id)
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
