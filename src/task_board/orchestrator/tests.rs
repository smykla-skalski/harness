use tempfile::tempdir;

use super::*;
use crate::task_board::{
    DispatchAppliedTask, TaskBoardEvaluationRecord, TaskBoardEvaluationSummary, TaskBoardItem,
    TaskBoardStatus,
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
                    item: applied_item,
                }],
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
