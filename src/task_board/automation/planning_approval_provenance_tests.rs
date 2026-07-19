use super::planning_approval_tests::{binding, invalidations, plan, snapshot};
use super::*;

#[test]
fn only_write_workflow_kinds_support_planning_approval() {
    for workflow_kind in [
        TaskBoardWorkflowKind::DefaultTask,
        TaskBoardWorkflowKind::PrFix,
    ] {
        let mut snapshot = snapshot();
        snapshot.workflow_kind = workflow_kind;
        let plan = build_planning_result("# Plan", Vec::new(), &snapshot, "execution-1")
            .expect("supported planning result");
        assert!(binding(&plan, &snapshot).workflow_kind == workflow_kind);
    }

    let default_snapshot = snapshot();
    let default_plan = plan(&default_snapshot);
    let default_binding = binding(&default_plan, &default_snapshot);
    for workflow_kind in [
        TaskBoardWorkflowKind::PrReview,
        TaskBoardWorkflowKind::Review,
        TaskBoardWorkflowKind::Unknown,
    ] {
        let mut unsupported = default_snapshot.clone();
        unsupported.workflow_kind = workflow_kind;
        let expected = TaskBoardPlanningResultError::UnsupportedWorkflowKind { workflow_kind };
        assert_eq!(
            build_planning_result("# Plan", Vec::new(), &unsupported, "execution-1"),
            Err(expected.clone())
        );
        assert_eq!(
            validate_planning_result(&default_plan, &unsupported, "execution-1"),
            Err(expected.clone())
        );
        assert_eq!(
            bind_plan_approval(
                &default_plan,
                &unsupported,
                "execution-1",
                "operator",
                "2026-07-15T06:00:00Z",
            ),
            Err(expected)
        );
        assert_eq!(
            invalidations(&default_binding, &default_plan, &unsupported, "execution-1"),
            [
                TaskBoardPlanApprovalInvalidation::WorkflowChanged,
                TaskBoardPlanApprovalInvalidation::PlanningResultInvalid,
            ]
        );
    }
}

#[test]
fn malformed_snapshot_evidence_is_rejected_fail_closed() {
    let reject = |changed, expected| {
        assert_eq!(
            build_planning_result("# Plan", Vec::new(), &changed, "execution-1"),
            Err(expected)
        );
    };

    let mut changed = snapshot();
    changed.item_revision = 0;
    reject(
        changed,
        TaskBoardPlanningResultError::InvalidItemRevision { value: 0 },
    );
    let mut changed = snapshot();
    changed.configuration_revision = 0;
    reject(
        changed,
        TaskBoardPlanningResultError::InvalidConfigurationRevision { value: 0 },
    );
    let mut changed = snapshot();
    changed.policy_version = " policy-v1 ".into();
    reject(changed, TaskBoardPlanningResultError::InvalidPolicyVersion);
    let mut changed = snapshot();
    changed.provider_revision = Some(" ".into());
    reject(
        changed,
        TaskBoardPlanningResultError::InvalidProviderRevision,
    );
    let mut changed = snapshot();
    changed.execution_repository = Some(" ".into());
    reject(
        changed,
        TaskBoardPlanningResultError::InvalidExecutionRepository,
    );
}

#[test]
fn planning_result_rejects_cross_execution_workflow_and_repository_rebinding() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    assert_eq!(
        validate_planning_result(&plan, &snapshot, "execution-2"),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );
    assert_eq!(
        bind_plan_approval(
            &plan,
            &snapshot,
            "execution-2",
            "operator",
            "2026-07-15T06:00:00Z",
        ),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );

    let mut changed = snapshot.clone();
    changed.workflow_kind = TaskBoardWorkflowKind::PrFix;
    assert_eq!(
        validate_planning_result(&plan, &changed, "execution-1"),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );

    let mut changed = snapshot;
    changed.execution_repository = Some("sample/other".into());
    assert_eq!(
        validate_planning_result(&plan, &changed, "execution-1"),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );
}

#[test]
fn matching_forged_revision_evidence_cannot_reuse_an_old_plan_hash() {
    let snapshot = snapshot();
    let mut forged_snapshot = snapshot.clone();
    let mut forged_plan = plan(&snapshot);
    forged_snapshot.item_revision += 1;
    forged_plan.item_revision += 1;
    forged_snapshot.configuration_revision += 1;
    forged_plan.configuration_revision += 1;
    forged_snapshot.provider_revision = Some("remote-4".into());
    forged_plan.provider_revision = Some("remote-4".into());

    assert_eq!(
        validate_planning_result(&forged_plan, &forged_snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );
}

#[test]
fn noncanonical_reloaded_repository_binding_fails_closed() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);
    let mut serialized = serde_json::to_value(binding).expect("serialize binding");
    serialized["execution_repository"] = serde_json::Value::String(" ".into());
    let changed = serde_json::from_value::<TaskBoardPlanApprovalBinding>(serialized)
        .expect("deserialize binding");

    assert_eq!(
        invalidations(&changed, &plan, &snapshot, "execution-1"),
        [
            TaskBoardPlanApprovalInvalidation::RepositoryChanged,
            TaskBoardPlanApprovalInvalidation::ApprovalBindingInvalid,
            TaskBoardPlanApprovalInvalidation::PlanningResultInvalid,
        ]
    );
}
