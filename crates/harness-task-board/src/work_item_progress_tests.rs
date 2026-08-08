use super::*;

fn progress() -> TaskBoardWorkItemProgress {
    TaskBoardWorkItemProgress::new(
        "board-1".to_string(),
        "task-board-1".to_string(),
        Some("workflow-1".to_string()),
        "2026-08-08T00:00:00Z".to_string(),
    )
}

fn report(state: Option<TaskBoardWorkItemState>) -> TaskBoardWorkItemReport {
    TaskBoardWorkItemReport {
        actor: "agent-1".to_string(),
        state,
        summary: None,
        progress_percent: None,
        blocked_reason: None,
        attempt_id: None,
        item_revision: None,
        sequence: None,
        checkpoint_id: "checkpoint-1".to_string(),
        recorded_at: "2026-08-08T00:01:00Z".to_string(),
    }
}

fn applied(
    current: &TaskBoardWorkItemProgress,
    report: &TaskBoardWorkItemReport,
) -> TaskBoardWorkItemProgress {
    match apply_work_item_report(current, report) {
        TaskBoardWorkItemReportOutcome::Applied(progress) => progress,
        TaskBoardWorkItemReportOutcome::Ignored { rejection, .. } => {
            panic!("expected the report to apply, got {rejection:?}")
        }
    }
}

#[test]
fn checkpoint_records_its_summary_and_progress() {
    let mut report = report(None);
    report.summary = Some("wrote the failing test".to_string());
    report.progress_percent = Some(40);

    let updated = applied(&progress(), &report);

    assert_eq!(updated.summary.as_deref(), Some("wrote the failing test"));
    assert_eq!(updated.progress_percent, Some(40));
    assert_eq!(updated.report_sequence, 1);
    let checkpoint = updated.latest_checkpoint().expect("checkpoint recorded");
    assert_eq!(checkpoint.sequence, 1);
    assert_eq!(checkpoint.summary, "wrote the failing test");
    assert_eq!(checkpoint.actor, "agent-1");
}

#[test]
fn checkpoint_log_appends_in_order() {
    let mut first = report(Some(TaskBoardWorkItemState::Running));
    first.summary = Some("first".to_string());
    let mut second = report(None);
    second.summary = Some("second".to_string());
    second.checkpoint_id = "checkpoint-2".to_string();

    let updated = applied(&applied(&progress(), &first), &second);

    let sequences: Vec<u64> = updated
        .checkpoints
        .iter()
        .map(|checkpoint| checkpoint.sequence)
        .collect();
    assert_eq!(sequences, [1, 2]);
    assert_eq!(updated.report_sequence, 2);
}

#[test]
fn report_without_summary_records_no_checkpoint() {
    let updated = applied(&progress(), &report(Some(TaskBoardWorkItemState::Running)));

    assert!(updated.checkpoints.is_empty());
    assert_eq!(updated.state, TaskBoardWorkItemState::Running);
}

#[test]
fn blank_summary_records_no_checkpoint() {
    let mut report = report(None);
    report.summary = Some("   ".to_string());

    let updated = applied(&progress(), &report);

    assert!(updated.checkpoints.is_empty());
}

#[test]
fn review_handoff_preserves_attempt_identity_and_item_revision() {
    let mut report = report(Some(TaskBoardWorkItemState::AwaitingReview));
    report.attempt_id = Some("codex-dispatch-intent-1".to_string());
    report.item_revision = Some(7);
    report.summary = Some("ready for review".to_string());

    let updated = applied(&progress(), &report);

    assert_eq!(updated.state, TaskBoardWorkItemState::AwaitingReview);
    assert_eq!(
        updated.attempt_id.as_deref(),
        Some("codex-dispatch-intent-1")
    );
    assert_eq!(updated.item_revision, Some(7));
    assert_eq!(
        updated
            .latest_checkpoint()
            .and_then(|checkpoint| checkpoint.attempt_id.as_deref()),
        Some("codex-dispatch-intent-1")
    );
}

#[test]
fn later_report_keeps_the_handoff_attempt_when_it_names_none() {
    let mut handoff = report(Some(TaskBoardWorkItemState::AwaitingReview));
    handoff.attempt_id = Some("codex-1".to_string());
    handoff.item_revision = Some(7);
    let claimed = report(Some(TaskBoardWorkItemState::InReview));

    let updated = applied(&applied(&progress(), &handoff), &claimed);

    assert_eq!(updated.attempt_id.as_deref(), Some("codex-1"));
    assert_eq!(updated.item_revision, Some(7));
}

#[test]
fn completion_stamps_the_settlement_time() {
    let updated = applied(&progress(), &report(Some(TaskBoardWorkItemState::Done)));

    assert_eq!(updated.state, TaskBoardWorkItemState::Done);
    assert_eq!(
        updated.completed_at.as_deref(),
        Some("2026-08-08T00:01:00Z")
    );
}

#[test]
fn repeated_report_cannot_move_settled_work_backward() {
    let settled = applied(&progress(), &report(Some(TaskBoardWorkItemState::Done)));

    let outcome = apply_work_item_report(&settled, &report(Some(TaskBoardWorkItemState::Running)));

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::Terminal)
    );
    assert_eq!(outcome.progress().state, TaskBoardWorkItemState::Done);
}

#[test]
fn blocked_work_settles_its_worker_without_freezing_the_record() {
    let blocked = applied(&progress(), &report(Some(TaskBoardWorkItemState::Blocked)));

    assert!(blocked.state.is_settled());
    assert!(!blocked.state.is_terminal());
    assert_eq!(
        blocked.completed_at.as_deref(),
        Some("2026-08-08T00:01:00Z")
    );
}

#[test]
fn unblocking_reopens_the_record_and_drops_its_settlement_stamp() {
    let blocked = applied(&progress(), &report(Some(TaskBoardWorkItemState::Blocked)));

    let resumed = applied(&blocked, &report(Some(TaskBoardWorkItemState::Running)));

    assert_eq!(resumed.state, TaskBoardWorkItemState::Running);
    assert!(resumed.completed_at.is_none());
    assert!(resumed.blocked_reason.is_none());
}

#[test]
fn a_bare_checkpoint_marks_a_pending_worker_running() {
    let mut report = report(None);
    report.summary = Some("started on the failing test".to_string());

    let updated = applied(&progress(), &report);

    assert_eq!(updated.state, TaskBoardWorkItemState::Running);
}

#[test]
fn a_bare_checkpoint_resumes_work_a_review_sent_back() {
    let sent_back = applied(
        &progress(),
        &report(Some(TaskBoardWorkItemState::ChangesRequested)),
    );

    let updated = applied(&sent_back, &report(None));

    assert_eq!(updated.state, TaskBoardWorkItemState::Running);
}

#[test]
fn a_bare_checkpoint_never_pulls_work_back_out_of_review() {
    for state in [
        TaskBoardWorkItemState::AwaitingReview,
        TaskBoardWorkItemState::InReview,
    ] {
        let handed_off = applied(&progress(), &report(Some(state)));

        let updated = applied(&handed_off, &report(None));

        assert_eq!(updated.state, state, "{state:?}");
    }
}

#[test]
fn changes_requested_keeps_the_reason_the_review_sent_back() {
    let mut sent_back = report(Some(TaskBoardWorkItemState::ChangesRequested));
    sent_back.blocked_reason = Some("Needs one fix".to_string());

    let updated = applied(&progress(), &sent_back);

    assert_eq!(updated.blocked_reason.as_deref(), Some("Needs one fix"));
    assert_eq!(
        updated
            .project_workflow(&TaskBoardWorkflowState::default())
            .last_error
            .as_deref(),
        Some("Needs one fix")
    );
}

#[test]
fn resuming_after_a_review_drops_the_reason_it_sent_back() {
    let mut sent_back = report(Some(TaskBoardWorkItemState::ChangesRequested));
    sent_back.blocked_reason = Some("Needs one fix".to_string());
    let sent_back = applied(&progress(), &sent_back);

    let resumed = applied(&sent_back, &report(Some(TaskBoardWorkItemState::Running)));

    assert!(resumed.blocked_reason.is_none());
}

#[test]
fn only_stalled_states_carry_a_reason() {
    let carrying = [
        TaskBoardWorkItemState::Blocked,
        TaskBoardWorkItemState::ChangesRequested,
    ];
    for state in carrying {
        assert!(state.carries_reason(), "{state:?}");
    }
    for state in [
        TaskBoardWorkItemState::Pending,
        TaskBoardWorkItemState::Running,
        TaskBoardWorkItemState::AwaitingReview,
        TaskBoardWorkItemState::InReview,
        TaskBoardWorkItemState::Done,
    ] {
        assert!(!state.carries_reason(), "{state:?}");
    }
}

#[test]
fn out_of_order_report_is_refused() {
    let mut first = report(Some(TaskBoardWorkItemState::Running));
    first.sequence = Some(5);
    let mut stale = report(Some(TaskBoardWorkItemState::AwaitingReview));
    stale.sequence = Some(3);

    let outcome = apply_work_item_report(&applied(&progress(), &first), &stale);

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::StaleSequence)
    );
    assert_eq!(outcome.progress().state, TaskBoardWorkItemState::Running);
    assert_eq!(outcome.progress().report_sequence, 5);
}

#[test]
fn replayed_sequence_is_refused() {
    let mut first = report(Some(TaskBoardWorkItemState::Running));
    first.sequence = Some(1);
    let applied_once = applied(&progress(), &first);

    let outcome = apply_work_item_report(&applied_once, &first);

    assert_eq!(
        outcome.rejection(),
        Some(TaskBoardWorkItemReportRejection::StaleSequence)
    );
    assert_eq!(outcome.progress().checkpoints.len(), 0);
}

#[test]
fn changes_requested_can_return_work_to_the_worker() {
    let handed_off = applied(
        &progress(),
        &report(Some(TaskBoardWorkItemState::AwaitingReview)),
    );
    let in_review = applied(&handed_off, &report(Some(TaskBoardWorkItemState::InReview)));
    let changes = applied(
        &in_review,
        &report(Some(TaskBoardWorkItemState::ChangesRequested)),
    );

    let resumed = applied(&changes, &report(Some(TaskBoardWorkItemState::Running)));

    assert_eq!(resumed.state, TaskBoardWorkItemState::Running);
}

#[test]
fn blocking_records_a_reason_and_clearing_it_drops_the_reason() {
    let mut blocked_report = report(Some(TaskBoardWorkItemState::Blocked));
    blocked_report.blocked_reason = Some("needs a human decision".to_string());

    let blocked = applied(&progress(), &blocked_report);

    assert_eq!(
        blocked.blocked_reason.as_deref(),
        Some("needs a human decision")
    );
    assert_eq!(blocked.state.board_status(), TaskBoardStatus::Failed);
}

#[test]
fn blocking_without_an_explicit_reason_falls_back_to_the_summary() {
    let mut blocked_report = report(Some(TaskBoardWorkItemState::Blocked));
    blocked_report.summary = Some("no completion evidence".to_string());

    let blocked = applied(&progress(), &blocked_report);

    assert_eq!(
        blocked.blocked_reason.as_deref(),
        Some("no completion evidence")
    );
}

#[test]
fn progress_percent_is_clamped_to_the_documented_ceiling() {
    let mut report = report(None);
    report.summary = Some("done-ish".to_string());
    report.progress_percent = Some(240);

    let updated = applied(&progress(), &report);

    assert_eq!(updated.progress_percent, Some(100));
    assert_eq!(
        updated
            .latest_checkpoint()
            .and_then(|checkpoint| checkpoint.progress_percent),
        Some(100)
    );
}

#[test]
fn long_summaries_are_truncated() {
    let mut report = report(None);
    report.summary = Some("x".repeat(TASK_BOARD_WORK_ITEM_SUMMARY_LIMIT + 10));

    let updated = applied(&progress(), &report);

    let summary = updated.summary.expect("summary recorded");
    assert_eq!(
        summary.chars().count(),
        TASK_BOARD_WORK_ITEM_SUMMARY_LIMIT + 1
    );
    assert!(summary.ends_with('…'));
}

#[test]
fn every_state_projects_a_board_lane_and_workflow_step() {
    let cases = [
        (
            TaskBoardWorkItemState::Pending,
            TaskBoardStatus::InProgress,
            TaskBoardWorkflowStatus::Running,
            "worker_pending",
        ),
        (
            TaskBoardWorkItemState::Running,
            TaskBoardStatus::InProgress,
            TaskBoardWorkflowStatus::Running,
            "worker",
        ),
        (
            TaskBoardWorkItemState::AwaitingReview,
            TaskBoardStatus::ToReview,
            TaskBoardWorkflowStatus::Running,
            "review_pending",
        ),
        (
            TaskBoardWorkItemState::InReview,
            TaskBoardStatus::InReview,
            TaskBoardWorkflowStatus::Running,
            "review",
        ),
        (
            TaskBoardWorkItemState::ChangesRequested,
            TaskBoardStatus::InReview,
            TaskBoardWorkflowStatus::Running,
            "review_changes_requested",
        ),
        (
            TaskBoardWorkItemState::Blocked,
            TaskBoardStatus::Failed,
            TaskBoardWorkflowStatus::Failed,
            "blocked",
        ),
        (
            TaskBoardWorkItemState::Done,
            TaskBoardStatus::Done,
            TaskBoardWorkflowStatus::Completed,
            "completed",
        ),
    ];

    for (state, board_status, workflow_status, step) in cases {
        assert_eq!(state.board_status(), board_status, "{state:?}");
        assert_eq!(state.workflow_status(), workflow_status, "{state:?}");
        assert_eq!(state.workflow_step(false), step, "{state:?}");
    }
}

#[test]
fn held_delivery_keeps_its_own_pending_step() {
    assert_eq!(
        TaskBoardWorkItemState::Pending.workflow_step(true),
        "awaiting_delivery"
    );
}

#[test]
fn projection_preserves_execution_binding_and_attempt_history() {
    let mut workflow = TaskBoardWorkflowState {
        execution_id: Some("workflow-1".to_string()),
        attempts: 3,
        policy_trace_ids: vec!["trace-1".to_string()],
        ..TaskBoardWorkflowState::default()
    };
    workflow.current_step_id = Some("awaiting_delivery".to_string());
    let progress = progress();

    let projected = progress.project_workflow(&workflow);

    assert_eq!(projected.execution_id.as_deref(), Some("workflow-1"));
    assert_eq!(projected.attempts, 3);
    assert_eq!(projected.policy_trace_ids, ["trace-1"]);
    assert_eq!(
        projected.current_step_id.as_deref(),
        Some("awaiting_delivery")
    );
}

#[test]
fn projection_surfaces_the_block_reason_as_the_workflow_error() {
    let mut blocked_report = report(Some(TaskBoardWorkItemState::Blocked));
    blocked_report.blocked_reason = Some("worktree unchanged".to_string());
    let blocked = applied(&progress(), &blocked_report);

    let projected = blocked.project_workflow(&TaskBoardWorkflowState::default());

    assert_eq!(projected.status, TaskBoardWorkflowStatus::Failed);
    assert_eq!(projected.last_error.as_deref(), Some("worktree unchanged"));
}

#[test]
fn persisted_state_spellings_round_trip() {
    let states = [
        TaskBoardWorkItemState::Pending,
        TaskBoardWorkItemState::Running,
        TaskBoardWorkItemState::AwaitingReview,
        TaskBoardWorkItemState::InReview,
        TaskBoardWorkItemState::ChangesRequested,
        TaskBoardWorkItemState::Blocked,
        TaskBoardWorkItemState::Done,
    ];

    for state in states {
        assert_eq!(
            TaskBoardWorkItemState::from_str_opt(state.as_str()),
            Some(state),
            "{state:?}"
        );
    }
    assert_eq!(TaskBoardWorkItemState::from_str_opt("nonsense"), None);
}
