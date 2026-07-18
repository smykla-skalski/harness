use super::*;

pub(super) fn snapshot() -> TaskBoardWorkflowSnapshot {
    TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: Some("sample/widgets".into()),
        item_revision: 7,
        configuration_revision: 11,
        policy_version: "policy-v1".into(),
        reviewer: TaskBoardResolvedReviewer {
            reviewer_count: 1,
            required_approvals: 1,
            max_revision_cycles: 3,
            profiles: vec![TaskBoardReviewerProfile::default()],
        },
        provider_revision: Some("remote-3".into()),
    }
}

pub(super) fn plan(snapshot: &TaskBoardWorkflowSnapshot) -> TaskBoardPlanningResult {
    build_planning_result(
        "# Plan\n\nImplement the workflow.",
        vec!["The focused test passes.".into()],
        snapshot,
        "execution-1",
    )
    .expect("build plan")
}

pub(super) fn binding(
    plan: &TaskBoardPlanningResult,
    snapshot: &TaskBoardWorkflowSnapshot,
) -> TaskBoardPlanApprovalBinding {
    bind_plan_approval(
        plan,
        snapshot,
        "execution-1",
        "operator",
        "2026-07-15T06:00:00Z",
    )
    .expect("bind approval")
}

pub(super) fn invalidations(
    binding: &TaskBoardPlanApprovalBinding,
    plan: &TaskBoardPlanningResult,
    snapshot: &TaskBoardWorkflowSnapshot,
    execution_id: &str,
) -> Vec<TaskBoardPlanApprovalInvalidation> {
    validate_plan_approval(binding, plan, snapshot, execution_id).invalidations
}

#[test]
fn normalization_preserves_markdown_hard_breaks_and_indented_code() {
    let snapshot = snapshot();
    let result = build_planning_result(
        " \r\n    code();\r\nLine one.  \r\nnext\r\n\t\r\n",
        vec![
            " \r\n  Criterion.  \r\n detail  \r\n ".into(),
            " \r\n  ".into(),
        ],
        &snapshot,
        "execution-1",
    )
    .expect("build normalized plan");

    assert_eq!(result.plan_markdown, "    code();\nLine one.  \nnext");
    assert_eq!(result.acceptance_criteria, ["  Criterion.  \n detail  "]);
}

#[test]
fn plan_hash_is_stable_and_domain_separated() {
    let snapshot = snapshot();
    let unix = compute_plan_hash(
        "execution-1",
        &snapshot,
        "# Plan\n\nImplement the workflow.",
        &["The focused test passes.".into()],
    );
    let platform = compute_plan_hash(
        "execution-1",
        &snapshot,
        " \r\n# Plan\r\n\r\nImplement the workflow.\r\n \r\n",
        &["\r\nThe focused test passes.\r\n".into()],
    );

    assert_eq!(unix, platform);
    assert_eq!(
        unix,
        "sha256:d0baebbc4a6b4605b28510c71b78565b9a8aa51fab37672ce464ea5c26be7ffa"
    );
}

#[test]
fn bound_approval_captures_exact_evidence_and_canonical_time() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);

    let binding = bind_plan_approval(
        &plan,
        &snapshot,
        " execution-1 ",
        " operator ",
        "2026-07-15T08:00:00+02:00",
    )
    .expect("bind approval");

    assert_eq!(
        binding,
        TaskBoardPlanApprovalBinding {
            execution_id: "execution-1".into(),
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            execution_repository: Some("sample/widgets".into()),
            plan_hash: plan.plan_hash.clone(),
            item_revision: 7,
            configuration_revision: 11,
            policy_version: "policy-v1".into(),
            provider_revision: Some("remote-3".into()),
            approved_by: "operator".into(),
            approved_at: "2026-07-15T06:00:00Z".into(),
        }
    );
    assert!(validate_plan_approval(&binding, &plan, &snapshot, "execution-1").valid);
}

#[test]
fn empty_and_malformed_fields_are_rejected() {
    let snapshot = snapshot();
    assert_eq!(
        build_planning_result(" \r\n \t", Vec::new(), &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::EmptyPlan)
    );
    assert_eq!(
        build_planning_result("# Plan", Vec::new(), &snapshot, " \t"),
        Err(TaskBoardPlanningResultError::EmptyExecutionId)
    );

    let plan = plan(&snapshot);
    assert_eq!(
        bind_plan_approval(&plan, &snapshot, " \t", "operator", "2026-07-15T06:00:00Z",),
        Err(TaskBoardPlanningResultError::EmptyExecutionId)
    );
    assert_eq!(
        bind_plan_approval(
            &plan,
            &snapshot,
            "execution-1",
            " \t",
            "2026-07-15T06:00:00Z",
        ),
        Err(TaskBoardPlanningResultError::EmptyApprover)
    );
    assert_eq!(
        bind_plan_approval(&plan, &snapshot, "execution-1", "operator", "not-a-time",),
        Err(TaskBoardPlanningResultError::InvalidApprovalTime {
            value: "not-a-time".into(),
        })
    );
}

#[test]
fn reloaded_binding_rejects_empty_or_noncanonical_approval_metadata() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);
    let tamper = |field: &str, value: &str| {
        let mut serialized = serde_json::to_value(&binding).expect("serialize binding");
        serialized[field] = serde_json::Value::String(value.into());
        serde_json::from_value::<TaskBoardPlanApprovalBinding>(serialized)
            .expect("deserialize tampered binding")
    };

    let changed = tamper("approved_by", "");
    assert_eq!(
        invalidations(&changed, &plan, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::ApprovalBindingInvalid]
    );

    let changed = tamper("approved_at", "not-a-time");
    assert_eq!(
        invalidations(&changed, &plan, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::ApprovalBindingInvalid]
    );

    let changed = tamper("approved_at", "2026-07-15T06:00:00+00:00");
    assert_eq!(
        invalidations(&changed, &plan, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::ApprovalBindingInvalid]
    );

    let changed = tamper("policy_version", "policy-v2");
    assert_eq!(
        invalidations(&changed, &plan, &snapshot, "execution-1"),
        [
            TaskBoardPlanApprovalInvalidation::PolicyVersionChanged,
            TaskBoardPlanApprovalInvalidation::PlanningResultInvalid,
        ]
    );
}

#[test]
fn reloaded_plan_rejects_noncanonical_markdown_and_criteria() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);

    let mut serialized = serde_json::to_value(&plan).expect("serialize plan");
    serialized["plan_markdown"] =
        serde_json::Value::String("\r\n# Plan\r\n\r\nImplement the workflow.\r\n".into());
    let changed = serde_json::from_value::<TaskBoardPlanningResult>(serialized)
        .expect("deserialize markdown-tampered plan");
    assert_eq!(
        validate_planning_result(&changed, &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::NonCanonicalPlanMarkdown)
    );
    assert_eq!(
        invalidations(&binding, &changed, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::PlanningResultInvalid]
    );

    let mut serialized = serde_json::to_value(&plan).expect("serialize plan");
    serialized["acceptance_criteria"] = serde_json::json!(["\r\nThe focused test passes.\r\n"]);
    let changed = serde_json::from_value::<TaskBoardPlanningResult>(serialized)
        .expect("deserialize criteria-tampered plan");
    assert_eq!(
        validate_planning_result(&changed, &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::NonCanonicalAcceptanceCriteria)
    );
    assert_eq!(
        invalidations(&binding, &changed, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::PlanningResultInvalid]
    );
}

#[test]
fn markdown_semantic_tampering_with_a_stale_hash_is_invalid() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);
    let mut changed = plan.clone();
    changed.plan_markdown.insert_str(0, "    ");
    changed
        .plan_markdown
        .push_str("\n\nHard break.  \ncontinued");

    assert_eq!(
        invalidations(&binding, &changed, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::PlanningResultInvalid]
    );
}

#[test]
fn hash_tampering_is_distinct_from_a_consistent_new_plan() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);
    let mut tampered = plan.clone();
    tampered.plan_hash = "sha256:tampered".into();

    assert_eq!(
        invalidations(&binding, &tampered, &snapshot, "execution-1"),
        [
            TaskBoardPlanApprovalInvalidation::PlanChanged,
            TaskBoardPlanApprovalInvalidation::PlanningResultInvalid,
        ]
    );

    let changed = build_planning_result(
        "# Plan\n\nUse a different implementation.",
        plan.acceptance_criteria.clone(),
        &snapshot,
        "execution-1",
    )
    .expect("rebuild plan");
    assert_eq!(
        invalidations(&binding, &changed, &snapshot, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::PlanChanged]
    );
}

#[test]
fn planning_result_validation_rejects_hash_and_each_revision_mismatch() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);

    let mut changed = plan.clone();
    changed.plan_hash = "sha256:tampered".into();
    assert_eq!(
        validate_planning_result(&changed, &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );

    let mut changed = plan.clone();
    changed.item_revision += 1;
    assert_eq!(
        validate_planning_result(&changed, &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::ItemRevisionMismatch)
    );

    let mut changed = plan.clone();
    changed.configuration_revision += 1;
    assert_eq!(
        validate_planning_result(&changed, &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::ConfigurationRevisionMismatch)
    );

    let mut changed = plan;
    changed.provider_revision = Some("remote-4".into());
    assert_eq!(
        validate_planning_result(&changed, &snapshot, "execution-1"),
        Err(TaskBoardPlanningResultError::ProviderRevisionMismatch)
    );
}

#[test]
fn every_provenance_drift_has_one_specific_invalidation() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);

    assert_eq!(
        invalidations(&binding, &plan, &snapshot, "execution-2"),
        [TaskBoardPlanApprovalInvalidation::ExecutionChanged]
    );

    let mut changed = snapshot.clone();
    changed.workflow_kind = TaskBoardWorkflowKind::PrFix;
    assert_eq!(
        invalidations(&binding, &plan, &changed, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::WorkflowChanged]
    );

    let mut changed = snapshot.clone();
    changed.execution_repository = Some("sample/other".into());
    assert_eq!(
        invalidations(&binding, &plan, &changed, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::RepositoryChanged]
    );

    let mut changed = snapshot.clone();
    changed.item_revision += 1;
    assert_eq!(
        invalidations(&binding, &plan, &changed, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::ItemRevisionChanged]
    );

    let mut changed = snapshot.clone();
    changed.configuration_revision += 1;
    assert_eq!(
        invalidations(&binding, &plan, &changed, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::ConfigurationRevisionChanged]
    );

    let mut changed = snapshot.clone();
    changed.policy_version = "policy-v2".into();
    assert_eq!(
        validate_planning_result(&plan, &changed, "execution-1"),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );
    assert_eq!(
        bind_plan_approval(
            &plan,
            &changed,
            "execution-1",
            "operator",
            "2026-07-15T06:00:00Z",
        ),
        Err(TaskBoardPlanningResultError::InvalidPlanHash)
    );
    assert_eq!(
        invalidations(&binding, &plan, &changed, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::PolicyVersionChanged]
    );

    let mut changed = snapshot.clone();
    changed.provider_revision = Some("remote-4".into());
    assert_eq!(
        invalidations(&binding, &plan, &changed, "execution-1"),
        [TaskBoardPlanApprovalInvalidation::ProviderRevisionChanged]
    );
}

#[test]
fn planning_result_revision_tampering_is_reported_specifically() {
    let snapshot = snapshot();
    let mut plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);
    plan.item_revision += 1;
    plan.configuration_revision += 1;
    plan.provider_revision = Some("remote-4".into());

    assert_eq!(
        invalidations(&binding, &plan, &snapshot, "execution-1"),
        [
            TaskBoardPlanApprovalInvalidation::ItemRevisionChanged,
            TaskBoardPlanApprovalInvalidation::ConfigurationRevisionChanged,
            TaskBoardPlanApprovalInvalidation::ProviderRevisionChanged,
        ]
    );
}

#[test]
fn all_invalidations_use_fixed_domain_order() {
    let snapshot = snapshot();
    let plan = plan(&snapshot);
    let binding = binding(&plan, &snapshot);
    let mut changed_snapshot = snapshot.clone();
    changed_snapshot.workflow_kind = TaskBoardWorkflowKind::PrFix;
    changed_snapshot.execution_repository = Some("sample/other".into());
    changed_snapshot.item_revision += 1;
    changed_snapshot.configuration_revision += 1;
    changed_snapshot.policy_version = "policy-v2".into();
    changed_snapshot.provider_revision = Some("remote-4".into());
    let mut changed_plan = plan.clone();
    changed_plan.plan_hash = "sha256:tampered".into();
    let mut changed_binding = binding;
    changed_binding.approved_by.clear();

    assert_eq!(
        invalidations(
            &changed_binding,
            &changed_plan,
            &changed_snapshot,
            "execution-2",
        ),
        [
            TaskBoardPlanApprovalInvalidation::ExecutionChanged,
            TaskBoardPlanApprovalInvalidation::WorkflowChanged,
            TaskBoardPlanApprovalInvalidation::RepositoryChanged,
            TaskBoardPlanApprovalInvalidation::PlanChanged,
            TaskBoardPlanApprovalInvalidation::ItemRevisionChanged,
            TaskBoardPlanApprovalInvalidation::ConfigurationRevisionChanged,
            TaskBoardPlanApprovalInvalidation::PolicyVersionChanged,
            TaskBoardPlanApprovalInvalidation::ProviderRevisionChanged,
            TaskBoardPlanApprovalInvalidation::ApprovalBindingInvalid,
            TaskBoardPlanApprovalInvalidation::PlanningResultInvalid,
        ]
    );
}
