use harness_protocol::agent::{AckResult, SignalAck};
use harness_protocol::daemon::activity::{
    AgentWorkspaceSignalCancelRequest, AgentWorkspaceSignalSendRequest,
};
use harness_protocol::session::{SessionRole, SessionSignalStatus};

use super::*;
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::db_open::AsyncDaemonDbConnect;

#[test]
fn workspace_signal_delivery_and_runtime_ack_do_not_require_a_session_route() {
    with_temp_project(|project| {
        temp_env::with_var(
            "CODEX_SESSION_ID",
            Some("workspace-activity-worker"),
            || {
                let runtime = tokio::runtime::Runtime::new().expect("runtime");
                runtime.block_on(async {
                    let fixture = seed_workspace_activity_member(project).await;
                    assert_workspace_signal_round_trip(project, &fixture).await;
                });
            },
        );
    });
}

struct WorkspaceActivityFixture {
    db: AsyncDaemonDbHandle,
    session_id: &'static str,
    workspace_id: String,
    member_id: String,
}

async fn seed_workspace_activity_member(project: &std::path::Path) -> WorkspaceActivityFixture {
    let db_path = project
        .parent()
        .expect("project parent")
        .join("daemon.sqlite");
    let db = crate::daemon::db::AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let db = AsyncDaemonDbHandle(db);
    let session_id = "18c6b928-cc3f-57ad-8d6e-a0874fd5daed";
    start_direct_session_async(
        &db,
        project,
        session_id,
        "workspace activity",
        "workspace activity",
        None,
    )
    .await;
    join_session_direct_async(
        session_id,
        &crate::daemon::protocol::SessionJoinRequest {
            runtime: "codex".into(),
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: vec![],
            name: None,
            project_dir: project.to_string_lossy().into(),
            persona: None,
        },
        &db,
    )
    .await
    .expect("join workspace activity worker");
    sqlx::query(
        "UPDATE agents
         SET managed_agent_kind = 'acp',
             managed_agent_id = 'acp-workspace-activity'
         WHERE session_id = ?1
           AND agent_session_id = 'workspace-activity-worker'",
    )
    .bind(session_id)
    .execute(db.pool())
    .await
    .expect("register managed workspace activity worker");
    let daemon_id = crate::daemon::state::ensure_daemon_identity()
        .expect("ensure daemon identity")
        .daemon_id;
    let workspace_id = db
        .reconcile_agent_workspaces(&daemon_id)
        .await
        .expect("reconcile durable workspace")
        .workspaces[0]
        .workspace_id
        .clone();
    let member_id = db
        .reconcile_agent_workspace_team(&daemon_id, &workspace_id)
        .await
        .expect("reconcile durable team")
        .team
        .expect("durable team")
        .members
        .into_iter()
        .find(|member| member.runtime_session_id.as_deref() == Some("workspace-activity-worker"))
        .expect("durable Codex member")
        .member_id;
    WorkspaceActivityFixture {
        db,
        session_id,
        workspace_id,
        member_id,
    }
}

async fn assert_workspace_signal_round_trip(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    assert_pending_signal_cancellation(project, fixture).await;
    assert_unavailable_signal_cancellation(project, fixture).await;
    let request = AgentWorkspaceSignalSendRequest {
        actor: "test".into(),
        idempotency_key: "round-trip-1".into(),
        command: "continue".into(),
        message: "Continue from durable workspace state".into(),
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
    .expect("send durable workspace signal");
    let retried = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &request,
        WakeDispatch::none(),
    )
    .await
    .expect("retry durable workspace signal after response loss");
    assert_eq!(sent.status, SessionSignalStatus::Pending);
    assert_eq!(retried.signal.signal_id, sent.signal.signal_id);
    let agent_runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = agent_runtime.signal_dir(project, "workspace-activity-worker");
    let pending =
        runtime::signal::read_pending_signals(&signal_dir).expect("read durable workspace signal");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].signal_id, sent.signal.signal_id);
    runtime::signal::acknowledge_signal(
        &signal_dir,
        &SignalAck {
            signal_id: sent.signal.signal_id.clone(),
            acknowledged_at: "2026-08-06T10:30:00Z".into(),
            result: AckResult::Accepted,
            agent: "workspace-activity-worker".into(),
            session_id: "runtime-only".into(),
            details: Some("received from runtime".into()),
        },
    )
    .expect("write runtime acknowledgment");
    assert_delivered_signal_cannot_be_cancelled(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &signal_dir,
    )
    .await;
    assert_durable_acknowledgment(&sent.signal.signal_id, fixture).await;
    assert_repeated_action_uses_a_new_operation(
        fixture,
        &request,
        &sent.signal.signal_id,
        &signal_dir,
    )
    .await;
    assert_failed_delivery_is_deferred(
        &fixture.db,
        fixture.session_id,
        &fixture.workspace_id,
        &fixture.member_id,
    )
    .await;
}

async fn assert_repeated_action_uses_a_new_operation(
    fixture: &WorkspaceActivityFixture,
    request: &AgentWorkspaceSignalSendRequest,
    original_signal_id: &str,
    signal_dir: &std::path::Path,
) {
    let repeated = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            idempotency_key: "round-trip-2".into(),
            ..request.clone()
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send the same action as a distinct operation");
    assert_ne!(repeated.signal.signal_id, original_signal_id);
    let repeated_pending = runtime::signal::read_pending_signals(&signal_dir)
        .expect("read intentionally repeated durable signal");
    assert!(
        repeated_pending
            .iter()
            .any(|signal| signal.signal_id == repeated.signal.signal_id)
    );
    cancel_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &repeated.signal.signal_id,
        &AgentWorkspaceSignalCancelRequest {
            actor: "test".into(),
        },
    )
    .await
    .expect("cancel intentionally repeated durable signal");
}

async fn assert_unavailable_signal_cancellation(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "test".into(),
            idempotency_key: "cancel-unavailable-1".into(),
            command: "cancel-unavailable".into(),
            message: "cancel while the runtime is unavailable".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send durable signal before runtime becomes unavailable");
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
            actor: "test".into(),
        },
    )
    .await
    .expect("cancel signal through persisted runtime coordinates");
    let runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = runtime.signal_dir(project, "workspace-activity-worker");
    let pending = runtime::signal::read_pending_signals(&signal_dir)
        .expect("read runtime queue after unavailable cancellation");
    assert_eq!(cancelled.status, SessionSignalStatus::Rejected);
    assert!(
        pending
            .iter()
            .all(|signal| signal.signal_id != sent.signal.signal_id)
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

async fn assert_pending_signal_cancellation(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "test".into(),
            idempotency_key: "cancel-1".into(),
            command: "cancel".into(),
            message: "cancel this durable signal".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send durable signal for cancellation");
    let request = AgentWorkspaceSignalCancelRequest {
        actor: "test".into(),
    };
    let cancelled = cancel_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &request,
    )
    .await
    .expect("cancel pending durable signal");
    let retried = cancel_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &sent.signal.signal_id,
        &request,
    )
    .await
    .expect("retry durable signal cancellation");
    assert_eq!(cancelled.status, SessionSignalStatus::Rejected);
    let first_acknowledgment = cancelled.acknowledgment.expect("first cancellation ack");
    let retried_acknowledgment = retried.acknowledgment.expect("retried cancellation ack");
    assert_eq!(
        first_acknowledgment.acknowledged_at,
        retried_acknowledgment.acknowledged_at
    );
    assert_eq!(first_acknowledgment.result, retried_acknowledgment.result);
    assert_eq!(first_acknowledgment.details, retried_acknowledgment.details);
    let runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = runtime.signal_dir(project, "workspace-activity-worker");
    let acknowledgment = runtime::signal::read_acknowledgments(&signal_dir)
        .expect("read cancellation acknowledgment")
        .into_iter()
        .find(|acknowledgment| acknowledgment.signal_id == sent.signal.signal_id)
        .expect("runtime cancellation acknowledgment");
    assert_eq!(acknowledgment.result, AckResult::Rejected);
}

async fn assert_durable_acknowledgment(signal_id: &str, fixture: &WorkspaceActivityFixture) {
    let activity = get_agent_workspace_member_activity_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
    )
    .await
    .expect("load workspace member activity");
    let signal = activity
        .signals
        .iter()
        .find(|record| record.signal.signal_id == signal_id)
        .expect("durable signal record");
    assert_eq!(signal.status, SessionSignalStatus::Delivered);
    let acknowledgment = signal.acknowledgment.as_ref().expect("durable ack");
    assert_eq!(acknowledgment.result, AckResult::Accepted);
    assert_eq!(acknowledgment.acknowledged_at, "2026-08-06T10:30:00Z");
    assert_eq!(acknowledgment.session_id, fixture.workspace_id);
    assert_eq!(acknowledgment.agent, fixture.member_id);
}

async fn assert_delivered_signal_cannot_be_cancelled(
    db: &AsyncDaemonDbHandle,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    signal_dir: &std::path::Path,
) {
    cancel_agent_workspace_signal_async(
        db,
        workspace_id,
        member_id,
        signal_id,
        &AgentWorkspaceSignalCancelRequest {
            actor: "test".into(),
        },
    )
    .await
    .expect_err("delivered signal cancellation must fail");
    let acknowledgments = runtime::signal::read_acknowledgments(signal_dir)
        .expect("read runtime acknowledgment after rejected cancellation");
    let acknowledgment = acknowledgments
        .iter()
        .find(|acknowledgment| acknowledgment.signal_id == signal_id)
        .expect("preserved runtime acknowledgment");
    assert_eq!(acknowledgment.result, AckResult::Accepted);
}

async fn assert_failed_delivery_is_deferred(
    db: &AsyncDaemonDbHandle,
    session_id: &str,
    workspace_id: &str,
    member_id: &str,
) {
    sqlx::query("UPDATE agents SET runtime = 'unknown' WHERE session_id = ?1")
        .bind(session_id)
        .execute(db.pool())
        .await
        .expect("make durable runtime unsupported");
    send_agent_workspace_signal_async(
        db,
        workspace_id,
        member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "test".into(),
            idempotency_key: "failed-delivery-1".into(),
            command: "fail-delivery".into(),
            message: "exercise failed runtime delivery".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect_err("unsupported runtime delivery must fail");
    let activity = get_agent_workspace_member_activity_async(db, workspace_id, member_id)
        .await
        .expect("load deferred signal after delivery failure");
    let failed = activity
        .signals
        .iter()
        .find(|record| record.signal.command == "fail-delivery")
        .expect("failed delivery durable signal");
    assert_eq!(failed.status, SessionSignalStatus::Deferred);
    assert_eq!(
        failed.acknowledgment.as_ref().map(|ack| ack.result),
        Some(AckResult::Deferred)
    );
}
