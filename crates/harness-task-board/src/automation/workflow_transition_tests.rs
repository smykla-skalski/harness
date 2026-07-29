use super::*;

fn pull_request(number: u64) -> TaskBoardPullRequestIdentity {
    TaskBoardPullRequestIdentity {
        repository: "example/compass".into(),
        number,
        head: None,
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
        task_board_workflow_phases(TaskBoardWorkflowKind::PR_FIX),
        write
    );
    assert_eq!(
        task_board_workflow_phases(TaskBoardWorkflowKind::PR_REVIEW),
        [
            TaskBoardExecutionPhase::Review,
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
        TaskBoardWorkflowKind::PR_FIX,
        Some(&identity),
        Some("head-base"),
    )
    .expect("start pr fix");
    assert_eq!(fix.pull_request.as_ref(), Some(&identity));
    assert_eq!(
        start_task_board_workflow(TaskBoardWorkflowKind::PR_FIX, None, Some("head-base")),
        Err(TaskBoardWorkflowTransitionError::MissingPullRequestIdentity)
    );
    assert_eq!(
        start_task_board_workflow(TaskBoardWorkflowKind::PR_FIX, Some(&identity), None),
        Err(TaskBoardWorkflowTransitionError::MissingHeadRevision)
    );
}

#[test]
fn pr_fix_freezes_fork_repository_branch_and_source_revision() {
    let identity = TaskBoardPullRequestIdentity {
        repository: "example/compass".into(),
        number: 41,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: "contributor/compass".into(),
            branch: "feature/fix".into(),
            revision: "source-head".into(),
        }),
    };
    let state = start_task_board_workflow(
        TaskBoardWorkflowKind::PR_FIX,
        Some(&identity),
        Some("source-head"),
    )
    .expect("start fork-backed PrFix");
    assert_eq!(state.pull_request.as_ref(), Some(&identity));

    let mut malformed = identity;
    malformed.head.as_mut().expect("head").branch = " ".into();
    assert_eq!(
        start_task_board_workflow(
            TaskBoardWorkflowKind::PR_FIX,
            Some(&malformed),
            Some("source-head"),
        ),
        Err(TaskBoardWorkflowTransitionError::MissingPullRequestHeadBranch)
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

    assert_eq!(
        restarted.phase,
        Some(TaskBoardExecutionPhase::Implementation)
    );
    assert_eq!(
        restarted.exact_head_revision.as_deref(),
        Some("head-reviewed")
    );
}

#[test]
fn pr_review_stays_on_exact_head_and_skips_evaluation_and_publish() {
    let identity = pull_request(23);
    let state = start_task_board_workflow(
        TaskBoardWorkflowKind::PR_REVIEW,
        Some(&identity),
        Some("head-indigo"),
    )
    .expect("start pr review");

    assert_eq!(
        advance_task_board_workflow(&state, None, Some("head-violet")),
        Err(TaskBoardWorkflowTransitionError::HeadRevisionChanged)
    );
    let cleanup = advance_task_board_workflow(&state, None, None).expect("advance to cleanup");
    assert_eq!(cleanup.phase, Some(TaskBoardExecutionPhase::Cleanup));
    assert_eq!(cleanup.exact_head_revision.as_deref(), Some("head-indigo"));
    assert_eq!(
        advance_task_board_workflow(&cleanup, None, None)
            .expect("advance to terminal")
            .phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );

    let mut forced_publish = state;
    forced_publish.phase = Some(TaskBoardExecutionPhase::Publish);
    assert_eq!(
        validate_task_board_workflow_transition_state(&forced_publish),
        Err(TaskBoardWorkflowTransitionError::InvalidPhase {
            workflow_kind: TaskBoardWorkflowKind::PR_REVIEW,
            phase: TaskBoardExecutionPhase::Publish,
        })
    );
}

#[test]
fn deserialized_pr_state_cannot_bypass_required_identity_or_head() {
    let identity = pull_request(29);
    let mut review = start_task_board_workflow(
        TaskBoardWorkflowKind::PR_REVIEW,
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
