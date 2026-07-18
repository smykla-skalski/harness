use super::*;

fn pull_request(number: u64) -> TaskBoardPullRequestIdentity {
    TaskBoardPullRequestIdentity {
        repository: "example/compass".into(),
        number,
    }
}

#[test]
fn workflow_definitions_have_the_exact_phase_sequences() {
    let write = [
        TaskBoardExecutionPhase::Planning,
        TaskBoardExecutionPhase::AwaitingApproval,
        TaskBoardExecutionPhase::Implementation,
        TaskBoardExecutionPhase::Review,
        TaskBoardExecutionPhase::Evaluate,
        TaskBoardExecutionPhase::Publish,
        TaskBoardExecutionPhase::Cleanup,
        TaskBoardExecutionPhase::Terminal,
    ];
    assert_eq!(
        task_board_workflow_phases(TaskBoardWorkflowKind::DefaultTask),
        write
    );
    assert_eq!(
        task_board_workflow_phases(TaskBoardWorkflowKind::PrFix),
        write
    );
    assert_eq!(
        task_board_workflow_phases(TaskBoardWorkflowKind::PrReview),
        [
            TaskBoardExecutionPhase::Review,
            TaskBoardExecutionPhase::Publish,
            TaskBoardExecutionPhase::Cleanup,
            TaskBoardExecutionPhase::Terminal,
        ]
    );
    assert_eq!(
        task_board_workflow_phases(TaskBoardWorkflowKind::Review),
        [
            TaskBoardExecutionPhase::Review,
            TaskBoardExecutionPhase::Evaluate,
            TaskBoardExecutionPhase::Cleanup,
            TaskBoardExecutionPhase::Terminal,
        ]
    );
}

#[test]
fn write_workflows_freeze_pr_identity_and_advance_through_approval() {
    let default = start_task_board_workflow(TaskBoardWorkflowKind::DefaultTask, None, None)
        .expect("start default task");
    assert_eq!(default.phase, Some(TaskBoardExecutionPhase::Planning));
    assert_eq!(
        advance_task_board_workflow(&default, None, None)
            .expect("await approval")
            .phase,
        Some(TaskBoardExecutionPhase::AwaitingApproval)
    );

    let identity = pull_request(41);
    let fix = start_task_board_workflow(
        TaskBoardWorkflowKind::PrFix,
        Some(&identity),
        Some("head-base"),
    )
    .expect("start pr fix");
    assert_eq!(fix.pull_request.as_ref(), Some(&identity));
    assert_eq!(
        start_task_board_workflow(TaskBoardWorkflowKind::PrFix, None, Some("head-base")),
        Err(TaskBoardWorkflowTransitionError::MissingPullRequestIdentity)
    );
    assert_eq!(
        start_task_board_workflow(TaskBoardWorkflowKind::PrFix, Some(&identity), None),
        Err(TaskBoardWorkflowTransitionError::MissingHeadRevision)
    );
}

#[test]
fn write_revision_cycle_retains_the_reviewed_head_as_next_base() {
    let mut state = start_task_board_workflow(TaskBoardWorkflowKind::DefaultTask, None, None)
        .expect("start default task");
    state.phase = Some(TaskBoardExecutionPhase::Review);
    state.execution_state = TaskBoardExecutionState::Running;
    state.exact_head_revision = Some("head-reviewed".into());

    let restarted = restart_task_board_workflow_revision(&state).expect("restart implementation");

    assert_eq!(restarted.phase, Some(TaskBoardExecutionPhase::Implementation));
    assert_eq!(restarted.exact_head_revision.as_deref(), Some("head-reviewed"));
}

#[test]
fn pr_review_stays_on_exact_head_and_skips_evaluation() {
    let identity = pull_request(23);
    let state = start_task_board_workflow(
        TaskBoardWorkflowKind::PrReview,
        Some(&identity),
        Some("head-indigo"),
    )
    .expect("start pr review");

    assert_eq!(
        advance_task_board_workflow(&state, None, Some("head-violet")),
        Err(TaskBoardWorkflowTransitionError::HeadRevisionChanged)
    );
    let publish = advance_task_board_workflow(&state, None, None).expect("advance to publish");
    assert_eq!(publish.phase, Some(TaskBoardExecutionPhase::Publish));
    assert_eq!(publish.exact_head_revision.as_deref(), Some("head-indigo"));
}

#[test]
fn deserialized_pr_state_cannot_bypass_required_identity_or_head() {
    let identity = pull_request(29);
    let mut review = start_task_board_workflow(
        TaskBoardWorkflowKind::PrReview,
        Some(&identity),
        Some("head-indigo"),
    )
    .expect("start pr review");
    review.exact_head_revision = None;
    assert_eq!(
        validate_task_board_workflow_transition_state(&review),
        Err(TaskBoardWorkflowTransitionError::MissingHeadRevision)
    );
    assert_eq!(
        advance_task_board_workflow(&review, None, None),
        Err(TaskBoardWorkflowTransitionError::MissingHeadRevision)
    );
}

#[test]
fn unknown_workflow_admits_no_phase_and_requires_human() {
    let state = start_task_board_workflow(TaskBoardWorkflowKind::Unknown, None, None)
        .expect("unknown resolves safely");

    assert!(task_board_workflow_phases(TaskBoardWorkflowKind::Unknown).is_empty());
    assert_eq!(state.phase, None);
    assert_eq!(
        state.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        advance_task_board_workflow(&state, None, None),
        Err(TaskBoardWorkflowTransitionError::NoAdmittedPhase)
    );
}
