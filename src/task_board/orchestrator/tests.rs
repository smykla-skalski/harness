use fs_err as fs;
use tempfile::tempdir;

use super::*;
use crate::task_board::{
    DispatchAppliedTask, ExternalProvider, ExternalSyncAction, ExternalSyncOperation,
    TaskBoardAutomationPolicy, TaskBoardEvaluationRecord, TaskBoardEvaluationSummary,
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus, build_dispatch_plan,
};

#[test]
fn restart_loads_persisted_settings_and_status() {
    let temp = tempdir().expect("tempdir");
    let first = TaskBoardOrchestrator::new(temp.path().join("board"));
    first.start().expect("start");
    first
        .update_settings(&TaskBoardOrchestratorSettingsUpdateRequest {
            dry_run_default: Some(false),
            project_dir: Some("/tmp/project".into()),
            ..TaskBoardOrchestratorSettingsUpdateRequest::default()
        })
        .expect("update settings");

    let restarted = TaskBoardOrchestrator::new(temp.path().join("board"));
    let status = restarted.status().expect("status");

    assert!(status.enabled);
    assert!(status.running);
    assert!(!status.settings.dry_run_default);
    assert_eq!(status.settings.project_dir.as_deref(), Some("/tmp/project"));
}

#[test]
fn autonomous_tick_runs_only_when_started() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let orchestrator = TaskBoardOrchestrator::new(root);

    let idle = orchestrator
        .run_autonomous_once(|_| panic!("stopped orchestrator must not dispatch"))
        .expect("idle status");
    assert!(!idle.running);
    assert!(idle.last_run.is_none());

    orchestrator.start().expect("start orchestrator");
    let running = orchestrator
        .run_autonomous_once(|input| {
            assert!(input.dry_run);
            Ok(DispatchExecutionSummary::dry_run(Vec::new()))
        })
        .expect("autonomous tick");

    assert_eq!(
        running.last_run.as_ref().map(|run| run.status),
        Some(TaskBoardOrchestratorRunStatus::Completed)
    );
}

#[test]
fn run_once_persists_summary_and_counts_workflow_statuses() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root.clone());
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Dispatch me".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    board.create("Dispatch me", "", item).expect("create item");
    let orchestrator = TaskBoardOrchestrator::new(root);

    let status = orchestrator
        .run_once(&TaskBoardOrchestratorRunOnceRequest::default(), |input| {
            assert!(input.dry_run);
            let mut applied_item = TaskBoardItem::new(
                "task-1".into(),
                "Dispatch me".into(),
                String::new(),
                "2026-05-14T00:00:00Z".into(),
            );
            applied_item.workflow.policy_trace_ids =
                vec!["trace-b".to_string(), "trace-a".to_string()];
            Ok(DispatchExecutionSummary {
                plans: Vec::new(),
                applied: vec![DispatchAppliedTask {
                    board_item_id: "task-1".to_string(),
                    session_id: "session-1".to_string(),
                    work_item_id: "work-1".to_string(),
                    lifecycle: build_dispatch_plan(&applied_item).applied_lifecycle(),
                    item: applied_item,
                }],
                failures: Vec::new(),
            })
        })
        .expect("run once");

    assert_eq!(
        status.last_run.as_ref().map(|run| run.status),
        Some(TaskBoardOrchestratorRunStatus::Completed)
    );
    assert_eq!(
        status
            .last_run
            .as_ref()
            .map(|run| run.policy_trace_ids.clone()),
        Some(vec!["trace-a".to_string(), "trace-b".to_string()])
    );
    assert_eq!(
        status.workflow_execution_counts,
        vec![TaskBoardWorkflowExecutionCount {
            status: TaskBoardWorkflowStatus::Running,
            count: 1,
        }]
    );
    assert!(status.current_tick.is_some());
}

#[test]
fn complete_run_records_evaluation_and_trace_ids() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root.clone());
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Evaluate me".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    board.create("Evaluate me", "", item).expect("create item");
    let orchestrator = TaskBoardOrchestrator::new(root);
    let prepared = orchestrator
        .prepare_run(&TaskBoardOrchestratorRunOnceRequest::default())
        .expect("prepare run");
    orchestrator
        .record_run_phase(&prepared, TaskBoardOrchestratorTickPhase::Evaluation)
        .expect("record evaluation phase");
    let in_flight_status = orchestrator.status().expect("in-flight status");
    assert_eq!(
        in_flight_status
            .current_tick
            .as_ref()
            .map(|tick| tick.phase),
        Some(TaskBoardOrchestratorTickPhase::Evaluation)
    );
    let mut evaluated_item = TaskBoardItem::new(
        "task-1".into(),
        "Evaluate me".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    evaluated_item.workflow.policy_trace_ids =
        vec!["trace-eval-b".to_string(), "trace-eval-a".to_string()];
    let evaluation = TaskBoardEvaluationSummary {
        total: 1,
        evaluated: 1,
        updated: 1,
        completed: 1,
        records: vec![TaskBoardEvaluationRecord {
            board_item_id: "task-1".to_string(),
            session_id: Some("session-1".to_string()),
            work_item_id: Some("work-1".to_string()),
            outcome: crate::task_board::TaskBoardEvaluationOutcome::Completed,
            task_status: None,
            board_status: Some(TaskBoardStatus::Done),
            workflow_status: Some(TaskBoardWorkflowStatus::Completed),
            updated: true,
            reason: None,
            item: Some(evaluated_item),
        }],
        ..TaskBoardEvaluationSummary::default()
    };

    let status = orchestrator
        .complete_run_with_evaluation(
            prepared,
            DispatchExecutionSummary::dry_run(Vec::new()),
            Some(evaluation),
        )
        .expect("complete run");

    let last_run = status.last_run.as_ref().expect("last run");
    assert_eq!(
        last_run.evaluation.as_ref().map(|summary| summary.updated),
        Some(1)
    );
    assert_eq!(
        last_run.policy_trace_ids,
        vec!["trace-eval-a".to_string(), "trace-eval-b".to_string()]
    );
    assert_eq!(status.last_run_applied_count(), 1);
}

#[test]
fn applied_count_includes_provider_mutations() {
    let temp = tempdir().expect("tempdir");
    let orchestrator = TaskBoardOrchestrator::new(temp.path().join("board"));
    let mut prepared = orchestrator
        .prepare_run(&TaskBoardOrchestratorRunOnceRequest::default())
        .expect("prepare run");
    prepared.sync.operations.push(ExternalSyncOperation {
        provider: ExternalProvider::GitHub,
        action: ExternalSyncAction::Pull,
        board_item_id: Some("task-neutral".into()),
        external_id: Some("item-17".into()),
        url: None,
        dry_run: false,
        applied: true,
        changed_fields: Vec::new(),
        unsupported_fields: Vec::new(),
    });

    let status = orchestrator
        .complete_run(prepared, DispatchExecutionSummary::dry_run(Vec::new()))
        .expect("complete run");

    assert_eq!(status.last_run_applied_count(), 1);
}

#[test]
fn partial_state_json_populates_defaults() {
    let state: TaskBoardOrchestratorState =
        serde_json::from_str("{}").expect("deserialize empty state");
    assert_eq!(state.schema_version, CURRENT_ORCHESTRATOR_STATE_VERSION);
    assert!(!state.enabled);
    assert!(!state.running);
    assert!(state.current_tick.is_none());
    assert!(state.last_run.is_none());
}

#[test]
fn partial_settings_json_populates_defaults() {
    let defaults = TaskBoardOrchestratorSettings::default();
    let settings: TaskBoardOrchestratorSettings =
        serde_json::from_str("{}").expect("deserialize empty settings");
    assert_eq!(settings.enabled_workflows, defaults.enabled_workflows);
    assert_eq!(settings.dry_run_default, defaults.dry_run_default);
    assert_eq!(settings.policy_version, defaults.policy_version);
    assert_eq!(
        settings.admission_policy,
        TaskBoardAutomationPolicy::default()
    );
}

#[test]
fn settings_read_repairs_legacy_dispatch_status_filter_on_disk() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    fs::create_dir_all(&root).expect("create board root");
    let settings_path = root.join(SETTINGS_FILE);
    fs::write(
        &settings_path,
        serde_json::to_vec_pretty(&serde_json::json!({
            "dispatch_status_filter": "needs_you"
        }))
        .expect("serialize settings"),
    )
    .expect("write settings");
    let orchestrator = TaskBoardOrchestrator::new(root);

    let settings = orchestrator.settings().expect("load settings");

    assert_eq!(
        settings.dispatch_status_filter,
        Some(TaskBoardStatus::HumanRequired)
    );
    let contents = fs::read_to_string(settings_path).expect("read repaired settings");
    assert!(contents.contains("\"dispatch_status_filter\": \"human_required\""));
    assert!(!contents.contains("\"dispatch_status_filter\": \"needs_you\""));
}

#[test]
fn settings_read_repairs_umbrella_filter_to_backlog_on_disk() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    fs::create_dir_all(&root).expect("create board root");
    let settings_path = root.join(SETTINGS_FILE);
    fs::write(
        &settings_path,
        serde_json::to_vec_pretty(&serde_json::json!({
            "dispatch_status_filter": "umbrella"
        }))
        .expect("serialize settings"),
    )
    .expect("write settings");
    let orchestrator = TaskBoardOrchestrator::new(root);

    let settings = orchestrator.settings().expect("load settings");

    assert_eq!(
        settings.dispatch_status_filter,
        Some(TaskBoardStatus::Backlog)
    );
    let contents = fs::read_to_string(settings_path).expect("read repaired settings");
    assert!(contents.contains("\"dispatch_status_filter\": \"backlog\""));
    assert!(!contents.contains("\"dispatch_status_filter\": \"umbrella\""));
}

#[test]
fn settings_update_writes_current_dispatch_status_filter() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let settings_path = root.join(SETTINGS_FILE);
    let orchestrator = TaskBoardOrchestrator::new(root);

    let settings = orchestrator
        .update_settings(&TaskBoardOrchestratorSettingsUpdateRequest {
            dispatch_status_filter: Some(TaskBoardStatus::PlanReview),
            ..TaskBoardOrchestratorSettingsUpdateRequest::default()
        })
        .expect("update settings");

    assert_eq!(
        settings.dispatch_status_filter,
        Some(TaskBoardStatus::AgenticReview)
    );
    let contents = fs::read_to_string(settings_path).expect("read current settings");
    assert!(contents.contains("\"dispatch_status_filter\": \"agentic_review\""));
    assert!(!contents.contains("\"dispatch_status_filter\": \"plan_review\""));
}

#[test]
fn dispatch_input_maps_legacy_filter_to_current_lane() {
    let settings = TaskBoardOrchestratorSettings::default();
    let request = TaskBoardOrchestratorRunOnceRequest {
        status: Some(TaskBoardStatus::Blocked),
        ..TaskBoardOrchestratorRunOnceRequest::default()
    };

    let input = settings::dispatch_input(&request, &settings);

    assert_eq!(input.status, Some(TaskBoardStatus::Failed));
}

#[test]
fn workflow_execution_counts_filter_by_local_machine_project_types() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root.clone());

    let mut mine = TaskBoardItem::new(
        "for-me".into(),
        "Mine".into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    mine.status = TaskBoardStatus::InProgress;
    mine.workflow.status = TaskBoardWorkflowStatus::Running;
    mine.target_project_types = vec!["web".into()];
    board.create("Mine", "", mine).expect("create mine");

    let mut other = TaskBoardItem::new(
        "for-other".into(),
        "Theirs".into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    other.status = TaskBoardStatus::InProgress;
    other.workflow.status = TaskBoardWorkflowStatus::Running;
    other.target_project_types = vec!["mobile".into()];
    board.create("Theirs", "", other).expect("create theirs");

    let orchestrator = TaskBoardOrchestrator::new(root);
    let registry = orchestrator.machine_registry();
    let mut local = orchestrator.local_machine().expect("ensure local");
    local.project_types = vec!["web".into()];
    registry.upsert(&local).expect("declare project types");

    let status = orchestrator.status().expect("status");

    assert_eq!(
        status.workflow_execution_counts,
        vec![TaskBoardWorkflowExecutionCount {
            status: TaskBoardWorkflowStatus::Running,
            count: 1,
        }],
        "mobile-only item must not contribute to the host's workflow counts"
    );
}

#[test]
fn dispatch_filters_items_that_target_other_machines() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root.clone());

    let mut mine = TaskBoardItem::new(
        "for-me".into(),
        "Mine".into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    mine.status = TaskBoardStatus::Todo;
    mine.target_project_types = vec!["web".into()];
    board.create("Mine", "", mine).expect("create mine");

    let mut other = TaskBoardItem::new(
        "for-other".into(),
        "Theirs".into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    other.status = TaskBoardStatus::Todo;
    other.target_project_types = vec!["data".into()];
    board.create("Theirs", "", other).expect("create theirs");

    let mut wildcard = TaskBoardItem::new(
        "wildcard".into(),
        "Anyone".into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    wildcard.status = TaskBoardStatus::Todo;
    board
        .create("Anyone", "", wildcard)
        .expect("create wildcard");

    let orchestrator = TaskBoardOrchestrator::new(root);
    let registry = orchestrator.machine_registry();
    let mut local = orchestrator.local_machine().expect("ensure local");
    local.project_types = vec!["web".into()];
    registry.upsert(&local).expect("declare project types");

    let prepared = orchestrator
        .prepare_run(&TaskBoardOrchestratorRunOnceRequest::default())
        .expect("prepare run");

    assert_eq!(
        prepared.audit.total, 2,
        "machine should keep web + wildcard, drop data"
    );
    let items = orchestrator
        .items_for_input(&prepared.input)
        .expect("items for input");
    let ids: Vec<&str> = items.iter().map(|item| item.id.as_str()).collect();
    assert!(ids.contains(&"for-me"));
    assert!(ids.contains(&"wildcard"));
    assert!(!ids.contains(&"for-other"));
}
