use super::*;

#[test]
fn external_status_reconciliation_preserves_workflow_and_tracks_provider_terminality() {
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::InProgress,
            Some(TaskBoardStatus::Backlog),
            TaskBoardStatus::Backlog,
        ),
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::Backlog,
            Some(TaskBoardStatus::Backlog),
            TaskBoardStatus::Done,
        ),
        TaskBoardStatus::Done
    );
    for observed in [TaskBoardStatus::Backlog, TaskBoardStatus::Done] {
        assert_eq!(
            reconciled_external_status(
                TaskBoardStatus::InProgress,
                Some(TaskBoardStatus::InProgress),
                observed,
            ),
            TaskBoardStatus::InProgress
        );
    }
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::Done,
            Some(TaskBoardStatus::Done),
            TaskBoardStatus::Backlog,
        ),
        TaskBoardStatus::Backlog
    );
    for last_synced in [TaskBoardStatus::Todo, TaskBoardStatus::Backlog] {
        assert_eq!(
            reconciled_external_status(
                TaskBoardStatus::Todo,
                Some(last_synced),
                TaskBoardStatus::Backlog,
            ),
            TaskBoardStatus::Todo
        );
    }
    for current in [TaskBoardStatus::Todo, TaskBoardStatus::Backlog] {
        assert_eq!(
            reconciled_external_status(current, None, TaskBoardStatus::Done),
            TaskBoardStatus::Done
        );
        assert_eq!(
            reconciled_external_status(current, Some(TaskBoardStatus::Done), TaskBoardStatus::Done,),
            current
        );
    }
    assert_eq!(
        reconciled_external_status(TaskBoardStatus::InProgress, None, TaskBoardStatus::Done),
        TaskBoardStatus::InProgress
    );
    assert_eq!(
        reconciled_external_status(
            TaskBoardStatus::Done,
            Some(TaskBoardStatus::Backlog),
            TaskBoardStatus::Backlog,
        ),
        TaskBoardStatus::Done
    );
    assert_eq!(
        reconciled_external_status(TaskBoardStatus::Done, None, TaskBoardStatus::Backlog),
        TaskBoardStatus::Done
    );
}

#[test]
fn external_status_reconciliation_canonicalizes_legacy_shared_truth() {
    for (current, last_synced, expected) in [
        (
            TaskBoardStatus::Todo,
            TaskBoardStatus::New,
            TaskBoardStatus::Done,
        ),
        (
            TaskBoardStatus::AgenticReview,
            TaskBoardStatus::PlanReview,
            TaskBoardStatus::AgenticReview,
        ),
        (
            TaskBoardStatus::HumanRequired,
            TaskBoardStatus::NeedsYou,
            TaskBoardStatus::HumanRequired,
        ),
        (
            TaskBoardStatus::Failed,
            TaskBoardStatus::Blocked,
            TaskBoardStatus::Failed,
        ),
    ] {
        assert_eq!(
            reconciled_external_status(current, Some(last_synced), TaskBoardStatus::Done),
            expected
        );
    }
}
