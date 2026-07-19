use tempfile::tempdir;

use super::*;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::handoff_outbox::HandoffRecord;
use crate::task_board::policy_runtime::models::{
    PolicyRunSubject, PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
};
use crate::task_board::policy_runtime::notification::NotificationRecord;
use crate::task_board::policy_runtime::repository::BeginRunOutcome;
use crate::task_board::policy_runtime::task_creation::TaskCreationRecord;
use crate::task_board::{
    ExternalRef, ExternalRefProvider, Machine, TaskBoardGitRuntimeConfig, TaskBoardItem,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorState, TaskBoardStatus,
};

mod admission_compensation;
mod admission_dispatch;
mod admission_evidence;
mod admission_lifecycle_tests;
mod dispatch;
mod dispatch_claims;
mod imports;
mod terminal_dispatch_lifecycle;
mod workflow_executions;
mod workflow_phase_settlement;
mod workflow_recovery_queue;
mod workflow_side_effect_claims;
mod workflow_verification_retry;

#[tokio::test]
async fn task_board_instance_identity_is_stable_per_database() {
    let dir = tempdir().expect("tempdir");
    let path = dir.path().join("harness.db");
    let first_db = AsyncDaemonDb::connect(&path).await.expect("open first db");
    let first = first_db
        .task_board_instance_id()
        .await
        .expect("first identity");
    let repeated = first_db
        .task_board_instance_id()
        .await
        .expect("repeated identity");
    assert_eq!(first, repeated);
    drop(first_db);

    let reopened = AsyncDaemonDb::connect(&path).await.expect("reopen db");
    assert_eq!(
        reopened
            .task_board_instance_id()
            .await
            .expect("reopened identity"),
        first
    );

    let other_dir = tempdir().expect("other tempdir");
    let other = AsyncDaemonDb::connect(&other_dir.path().join("harness.db"))
        .await
        .expect("open other db")
        .task_board_instance_id()
        .await
        .expect("other identity");
    assert_ne!(other, first);
}

#[tokio::test]
async fn task_board_items_round_trip_and_mutate_atomically() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut item = TaskBoardItem::new(
        "task-round-trip".to_owned(),
        "Original".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    item.external_refs.push(ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "owner/repo#42".to_owned(),
        url: Some("https://github.com/owner/repo/pull/42".to_owned()),
        sync_state: None,
    });

    let created = db
        .create_task_board_item(item.clone())
        .await
        .expect("create item");
    assert_eq!(created.item, item);
    assert!(created.change_revision > 0);
    assert_eq!(db.task_board_item(&item.id).await.expect("load item"), item);

    let updated = db
        .update_task_board_item(&item.id, |current| {
            current.title = "Updated".to_owned();
            current.status = TaskBoardStatus::New;
            Ok(true)
        })
        .await
        .expect("update item")
        .expect("mutation");
    assert_eq!(updated.item.title, "Updated");
    assert_eq!(updated.item.status, TaskBoardStatus::Todo);
    assert!(updated.change_revision > created.change_revision);

    let deleted = db
        .delete_task_board_item(&item.id)
        .await
        .expect("delete item");
    assert!(deleted.item.is_deleted());
    assert!(
        db.list_task_board_items(None)
            .await
            .expect("list active")
            .is_empty()
    );
    assert_eq!(
        db.list_task_board_items_including_deleted()
            .await
            .expect("list all")
            .len(),
        1
    );
}

#[tokio::test]
async fn v36_umbrella_rows_open_and_rewrite_as_backlog() {
    let dir = tempdir().expect("tempdir");
    let path = dir.path().join("harness.db");
    {
        let db = DaemonDb::open(&path).expect("create current database");
        db.connection()
            .execute_batch(
                "INSERT INTO task_board_items (
                     item_id, schema_version, title, body, status, priority, tags_json,
                     project_id, target_project_types_json, agent_mode, imported_from_provider,
                     planning_json, workflow_json, session_id, work_item_id, usage_json,
                     created_at, updated_at, deleted_at, revision, workflow_kind
                 ) VALUES (
                     'legacy-umbrella', 1, 'Legacy', '', 'umbrella', 'medium', '[]',
                     NULL, '[]', 'headless', 'github', '{}', '{}', NULL, NULL, '{}',
                     '2026-07-16T00:00:00Z', '2026-07-16T00:00:00Z', NULL, 1, 'review'
                 );
                 INSERT INTO task_board_external_refs (
                     item_id, position, provider, external_id, sync_state_json
                 ) VALUES (
                     'legacy-umbrella', 0, 'github', '42', '{\"status\":\"umbrella\"}'
                 );
                 UPDATE schema_meta SET value = '36' WHERE key = 'version';",
            )
            .expect("seed v36 umbrella rows");
    }

    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("open migrated database");
    let loaded = db
        .task_board_item("legacy-umbrella")
        .await
        .expect("load migrated item");
    assert_eq!(loaded.status, TaskBoardStatus::Backlog);
    assert_eq!(
        loaded.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Backlog)
    );
    db.update_task_board_item("legacy-umbrella", |item| {
        item.title = "Canonical".to_string();
        Ok(true)
    })
    .await
    .expect("rewrite migrated item")
    .expect("item changed");
    drop(db);

    let conn = Connection::open(&path).expect("inspect migrated database");
    let (status, sync_status): (String, String) = conn
        .query_row(
            "SELECT item.status, json_extract(reference.sync_state_json, '$.status')
             FROM task_board_items AS item
             JOIN task_board_external_refs AS reference ON reference.item_id = item.item_id
             WHERE item.item_id = 'legacy-umbrella'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read canonical status values");
    assert_eq!(status, "backlog");
    assert_eq!(sync_status, "backlog");
}

#[tokio::test]
async fn task_board_singletons_and_machine_registry_round_trip() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let machine = Machine::new("machine-1", "Local Mac");
    let (stored, _) = db
        .set_task_board_local_machine(&machine)
        .await
        .expect("set local machine");
    assert_eq!(
        db.task_board_local_machine_id()
            .await
            .expect("local id")
            .as_deref(),
        Some(stored.id.as_str())
    );
    assert_eq!(db.task_board_machines().await.expect("machines").len(), 1);

    let settings = TaskBoardOrchestratorSettings::default();
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("save settings");
    let settings_snapshot = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("load settings snapshot");
    assert_eq!(settings_snapshot.settings, settings);
    assert_eq!(settings_snapshot.row_revision, 2);
    assert!(settings_snapshot.change_revision > 0);
    assert_eq!(
        db.task_board_orchestrator_settings()
            .await
            .expect("load settings"),
        settings
    );

    let mut state = TaskBoardOrchestratorState::default();
    state.enabled = true;
    db.replace_task_board_orchestrator_state(&state)
        .await
        .expect("save state");
    let loaded_state = db
        .task_board_orchestrator_state()
        .await
        .expect("load state");
    assert_eq!(
        serde_json::to_value(loaded_state).expect("encode loaded state"),
        serde_json::to_value(state).expect("encode expected state")
    );

    let config = TaskBoardGitRuntimeConfig::default();
    db.replace_task_board_runtime_config(&config)
        .await
        .expect("save runtime config");
    assert_eq!(
        db.task_board_runtime_config()
            .await
            .expect("load runtime config"),
        config
    );
}

#[tokio::test]
async fn policy_runs_share_database_dedupe_and_claim_logic() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let run = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("owner/repo#42"),
        Some("head-sha".to_owned()),
        PolicyRunTrigger::Background,
        Vec::new(),
    );
    let now = chrono::DateTime::parse_from_rfc3339("2026-07-11T10:00:00Z")
        .expect("timestamp")
        .with_timezone(&chrono::Utc);
    let first = db
        .begin_policy_workflow_run(run.clone(), PolicyRunTrigger::Background, now)
        .await
        .expect("begin run");
    assert!(matches!(first, BeginRunOutcome::Created(_)));
    let second = db
        .begin_policy_workflow_run(run.clone(), PolicyRunTrigger::Background, now)
        .await
        .expect("dedupe run");
    assert!(matches!(second, BeginRunOutcome::Existing(_)));

    let mut waiting = run;
    waiting.mark_waiting(
        PolicyWaitCondition::Event {
            event_key: "checks_green".to_owned(),
        },
        1,
    );
    db.save_policy_workflow_run(&waiting)
        .await
        .expect("save waiting run");
    let event = PolicyWorkflowEvent::named("checks_green", "owner/repo#42");
    assert_eq!(
        db.policy_run_ids_ready_for_event(&event)
            .await
            .expect("event-ready runs"),
        vec![waiting.run_id.clone()]
    );
    assert!(
        db.claim_waiting_policy_run(&waiting.run_id, PolicyRunTrigger::Event)
            .await
            .expect("claim run")
            .is_some()
    );
    assert!(
        db.claim_waiting_policy_run(&waiting.run_id, PolicyRunTrigger::Event)
            .await
            .expect("claim run again")
            .is_none()
    );
}

#[tokio::test]
async fn policy_inbox_and_outboxes_round_trip_in_order() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let now = chrono::DateTime::parse_from_rfc3339("2026-07-11T10:00:00Z")
        .expect("timestamp")
        .with_timezone(&chrono::Utc);
    let event = PolicyWorkflowEvent {
        event_key: "checks_green".to_owned(),
        subject_key: "owner/repo#42".to_owned(),
        occurred_at: now.to_rfc3339(),
    };
    db.publish_policy_event_at(event.clone(), now)
        .await
        .expect("publish event");
    assert_eq!(
        db.pending_policy_events().await.expect("events"),
        vec![event]
    );

    db.record_policy_handoff_at(
        HandoffRecord {
            handoff_key: "copilot".to_owned(),
            workflow_id: "reviews_auto".to_owned(),
            subject_key: "owner/repo#42".to_owned(),
            recorded_at: now.to_rfc3339(),
        },
        now,
    )
    .await
    .expect("record handoff");
    db.record_policy_notification_at(
        NotificationRecord {
            channel: "review".to_owned(),
            message: "ready".to_owned(),
            workflow_id: "reviews_auto".to_owned(),
            subject_key: "owner/repo#42".to_owned(),
            recorded_at: now.to_rfc3339(),
        },
        now,
    )
    .await
    .expect("record notification");
    db.record_policy_task_creation_at(
        TaskCreationRecord {
            title: "Follow up".to_owned(),
            body: Some("details".to_owned()),
            workflow_id: "reviews_auto".to_owned(),
            subject_key: "owner/repo#42".to_owned(),
            recorded_at: now.to_rfc3339(),
        },
        now,
    )
    .await
    .expect("record task creation");
    assert_eq!(
        db.policy_handoff_records().await.expect("handoffs").len(),
        1
    );
    assert_eq!(
        db.policy_notification_records()
            .await
            .expect("notifications")
            .len(),
        1
    );
    assert_eq!(
        db.policy_task_creation_records()
            .await
            .expect("task creations")
            .len(),
        1
    );
}

#[tokio::test]
async fn malformed_policy_queue_timestamps_are_pruned_on_next_mutation() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let now = chrono::DateTime::parse_from_rfc3339("2026-07-11T10:00:00Z")
        .expect("timestamp")
        .with_timezone(&chrono::Utc);
    let malformed_event = PolicyWorkflowEvent {
        event_key: "malformed".to_owned(),
        subject_key: "owner/repo#42".to_owned(),
        occurred_at: "not-a-timestamp".to_owned(),
    };
    db.publish_policy_event_at(malformed_event, now)
        .await
        .expect("publish malformed event");
    let valid_event = PolicyWorkflowEvent {
        event_key: "valid".to_owned(),
        subject_key: "owner/repo#42".to_owned(),
        occurred_at: now.to_rfc3339(),
    };
    db.publish_policy_event_at(valid_event.clone(), now)
        .await
        .expect("publish valid event");
    assert_eq!(
        db.pending_policy_events().await.expect("events"),
        vec![valid_event]
    );

    db.record_policy_handoff_at(
        HandoffRecord {
            handoff_key: "malformed".to_owned(),
            workflow_id: "reviews_auto".to_owned(),
            subject_key: "owner/repo#42".to_owned(),
            recorded_at: "not-a-timestamp".to_owned(),
        },
        now,
    )
    .await
    .expect("record malformed handoff");
    db.record_policy_handoff_at(
        HandoffRecord {
            handoff_key: "valid".to_owned(),
            workflow_id: "reviews_auto".to_owned(),
            subject_key: "owner/repo#42".to_owned(),
            recorded_at: now.to_rfc3339(),
        },
        now,
    )
    .await
    .expect("record valid handoff");
    let handoffs = db.policy_handoff_records().await.expect("handoffs");
    assert_eq!(handoffs.len(), 1);
    assert_eq!(handoffs[0].handoff_key, "valid");
}
