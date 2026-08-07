use super::*;

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
