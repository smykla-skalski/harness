use super::*;

const REBOUND_SESSION_ID: &str = "28c6b928-cc3f-57ad-8d6e-a0874fd5daed";
const REBOUND_RUNTIME_SESSION_ID: &str = "workspace-activity-worker-rebound";
const ORIGINAL_SESSION_ID: &str = "18c6b928-cc3f-57ad-8d6e-a0874fd5daed";

pub(super) async fn record_and_assert_native_acknowledgment(
    signal_id: &str,
    fixture: &WorkspaceActivityFixture,
) {
    let target = fixture
        .db
        .load_agent_workspace_signal_target(
            &crate::daemon::state::ensure_daemon_identity()
                .expect("ensure daemon identity")
                .daemon_id,
            &fixture.workspace_id,
            &fixture.member_id,
        )
        .await
        .expect("load compatibility acknowledgment target");
    crate::daemon::service::record_signal_ack_direct_async(
        target.source_session_id.as_deref().expect("source session"),
        &SignalAckRequest {
            agent_id: target.source_agent_id.expect("source agent"),
            signal_id: signal_id.to_string(),
            result: AckResult::Accepted,
            project_dir: target.project_dir,
        },
        &fixture.db,
    )
    .await
    .expect("record compatibility acknowledgment through daemon service");

    let activity = get_agent_workspace_activity_async(
        &fixture.db,
        &fixture.workspace_id,
        &TimelineWindowRequest::default(),
    )
    .await
    .expect("load workspace timeline immediately after compatibility acknowledgment");
    let acknowledgment_count = activity
        .entries
        .unwrap_or_default()
        .iter()
        .filter(|entry| {
            entry.kind == "signal_acknowledged"
                && entry
                    .payload
                    .get("signal_id")
                    .and_then(|value| value.as_str())
                    == Some(signal_id)
        })
        .count();
    assert_eq!(acknowledgment_count, 1);

    let (status, acknowledgment_json) = sqlx::query_as::<_, (String, Option<String>)>(
        "SELECT status, ack_json FROM agent_workspace_signals
             WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .bind(signal_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load native signal ledger after compatibility acknowledgment");
    assert_eq!(status, "delivered");
    assert!(acknowledgment_json.is_some());

    let legacy_ack_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM session_log
         WHERE session_id = ?1 AND transition_kind = 'SignalAcknowledged'
           AND transition_json LIKE ?2",
    )
    .bind(fixture.session_id)
    .bind(format!("%{signal_id}%"))
    .fetch_one(fixture.db.pool())
    .await
    .expect("count legacy session acknowledgment rows");
    assert_eq!(legacy_ack_count, 0);
}

pub(super) async fn assert_delayed_ack_after_session_rebind(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
) {
    let original_target = fixture
        .db
        .load_agent_workspace_signal_target(
            &crate::daemon::state::ensure_daemon_identity()
                .expect("ensure daemon identity")
                .daemon_id,
            &fixture.workspace_id,
            &fixture.member_id,
        )
        .await
        .expect("load original delivery target");
    let source_agent_id = original_target.source_agent_id.expect("source agent");
    let direct_request = AgentWorkspaceSignalSendRequest {
        actor: "delayed-ack-test".into(),
        idempotency_key: "delayed-ack-after-rebind".into(),
        command: "continue".into(),
        message: "Import the delayed runtime acknowledgment".into(),
        action_hint: None,
    };
    let sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &direct_request,
        WakeDispatch::none(),
    )
    .await
    .expect("send signal through original delivery route");
    let recovery_sent = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &AgentWorkspaceSignalSendRequest {
            actor: "delayed-ack-test".into(),
            idempotency_key: "delayed-read-recovery-after-rebind".into(),
            command: "continue".into(),
            message: "Recover the delayed acknowledgment during a read".into(),
            action_hint: None,
        },
        WakeDispatch::none(),
    )
    .await
    .expect("send read-recovery signal through original route");

    delete_session_direct_async(fixture.session_id, &fixture.db)
        .await
        .expect("delete original Session");
    seed_rebound_member(project, fixture).await;
    let retried = send_agent_workspace_signal_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
        &direct_request,
        WakeDispatch::none(),
    )
    .await
    .expect("retry signal after member rebind");
    assert_eq!(retried.signal.signal_id, sent.signal.signal_id);
    assert_retry_uses_original_runtime(project, &sent.signal.signal_id);
    write_delayed_runtime_ack(project, &sent.signal.signal_id);
    write_delayed_runtime_ack(project, &recovery_sent.signal.signal_id);
    settle_delayed_acknowledgments(
        project,
        fixture,
        source_agent_id,
        &sent.signal.signal_id,
        &recovery_sent.signal.signal_id,
    )
    .await;
}

fn assert_retry_uses_original_runtime(project: &std::path::Path, signal_id: &str) {
    let runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let original_dir = runtime.signal_dir(project, "workspace-activity-worker");
    let rebound_dir = runtime.signal_dir(project, REBOUND_RUNTIME_SESSION_ID);
    assert!(
        runtime::signal::read_pending_signals(&original_dir)
            .expect("read original runtime queue")
            .iter()
            .any(|signal| signal.signal_id == signal_id)
    );
    assert!(
        runtime::signal::read_pending_signals(&rebound_dir)
            .expect("read rebound runtime queue")
            .iter()
            .all(|signal| signal.signal_id != signal_id)
    );
}

async fn settle_delayed_acknowledgments(
    project: &std::path::Path,
    fixture: &WorkspaceActivityFixture,
    source_agent_id: String,
    direct_signal_id: &str,
    recovery_signal_id: &str,
) {
    record_signal_ack_direct_async(
        fixture.session_id,
        &SignalAckRequest {
            agent_id: source_agent_id,
            signal_id: direct_signal_id.to_string(),
            result: AckResult::Accepted,
            project_dir: project.to_string_lossy().into(),
        },
        &fixture.db,
    )
    .await
    .expect("import delayed acknowledgment through original route");

    let (status, acknowledgment_json) = sqlx::query_as::<_, (String, Option<String>)>(
        "SELECT status, ack_json FROM agent_workspace_signals
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(&fixture.workspace_id)
    .bind(&fixture.member_id)
    .bind(direct_signal_id)
    .fetch_one(fixture.db.pool())
    .await
    .expect("load delayed durable acknowledgment");
    assert_eq!(status, "delivered");
    assert!(acknowledgment_json.is_some());

    let recovered = get_agent_workspace_member_activity_async(
        &fixture.db,
        &fixture.workspace_id,
        &fixture.member_id,
    )
    .await
    .expect("recover delayed acknowledgment during member read");
    let recovered_signal = recovered
        .signals
        .iter()
        .find(|record| record.signal.signal_id == recovery_signal_id)
        .expect("recovered delayed signal");
    assert_eq!(recovered_signal.status, SessionSignalStatus::Delivered);
    assert_eq!(
        recovered_signal
            .acknowledgment
            .as_ref()
            .expect("recovered acknowledgment")
            .result,
        AckResult::Accepted
    );
}

async fn seed_rebound_member(project: &std::path::Path, fixture: &WorkspaceActivityFixture) {
    start_direct_session_async(
        &fixture.db,
        project,
        REBOUND_SESSION_ID,
        "rebound workspace activity",
        "rebound workspace activity",
        None,
    )
    .await;
    temp_env::async_with_vars(
        [("CODEX_SESSION_ID", Some(REBOUND_RUNTIME_SESSION_ID))],
        join_session_direct_async(
            REBOUND_SESSION_ID,
            &crate::daemon::protocol::SessionJoinRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec![],
                name: None,
                project_dir: project.to_string_lossy().into(),
                persona: None,
            },
            &fixture.db,
        ),
    )
    .await
    .expect("join rebound workspace member");
    sqlx::query(
        "UPDATE agents
         SET managed_agent_kind = 'acp', managed_agent_id = 'acp-workspace-activity'
         WHERE session_id = ?1 AND agent_session_id = ?2",
    )
    .bind(REBOUND_SESSION_ID)
    .bind(REBOUND_RUNTIME_SESSION_ID)
    .execute(fixture.db.pool())
    .await
    .expect("register rebound managed identity");
    let daemon_id = crate::daemon::state::ensure_daemon_identity()
        .expect("ensure daemon identity")
        .daemon_id;
    fixture
        .db
        .reconcile_agent_workspaces(&daemon_id)
        .await
        .expect("reconcile rebound workspace");
    fixture
        .db
        .reconcile_agent_workspace_team(&daemon_id, &fixture.workspace_id)
        .await
        .expect("reconcile rebound member");
    let rebound = fixture
        .db
        .load_agent_workspace_signal_target(&daemon_id, &fixture.workspace_id, &fixture.member_id)
        .await
        .expect("load rebound member target");
    assert_eq!(
        rebound.source_session_id.as_deref(),
        Some(REBOUND_SESSION_ID)
    );
    assert_eq!(
        rebound.runtime_session_id.as_deref(),
        Some(REBOUND_RUNTIME_SESSION_ID)
    );
}

fn write_delayed_runtime_ack(project: &std::path::Path, signal_id: &str) {
    let runtime = runtime::runtime_for_name("codex").expect("Codex runtime");
    let signal_dir = runtime.signal_dir(project, "workspace-activity-worker");
    runtime::signal::acknowledge_signal(
        &signal_dir,
        &SignalAck {
            signal_id: signal_id.into(),
            acknowledged_at: "2026-08-06T11:30:00Z".into(),
            result: AckResult::Accepted,
            agent: "workspace-activity-worker".into(),
            session_id: ORIGINAL_SESSION_ID.into(),
            details: Some("delayed after Session deletion".into()),
        },
    )
    .expect("write delayed runtime acknowledgment");
}
