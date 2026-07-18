use super::*;

fn pull_request(number: u64) -> TaskBoardPullRequestIdentity {
    TaskBoardPullRequestIdentity {
        repository: "example/compass".into(),
        number,
    }
}

#[test]
fn workflow_definitions_have_the_exact_phase_sequences() {
    assert!(task_board_workflow_phases(TaskBoardWorkflowKind::DefaultTask).is_empty());
    assert!(task_board_workflow_phases(TaskBoardWorkflowKind::PrFix).is_empty());
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
fn write_workflows_are_explicitly_unsupported() {
    for workflow_kind in [
        TaskBoardWorkflowKind::DefaultTask,
        TaskBoardWorkflowKind::PrFix,
    ] {
        let state = start_task_board_workflow(workflow_kind, None, None).expect("safe refusal");
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
