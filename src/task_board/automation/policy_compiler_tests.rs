use super::*;

fn context(evaluated_at: &str) -> TaskBoardPolicyCompilationContext {
    TaskBoardPolicyCompilationContext {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        repository: Some("Example/Compass".into()),
        evaluated_at: evaluated_at.into(),
        estimated_tokens: Some(400),
        estimated_cost_microusd: Some(75_000),
    }
}

fn window(
    outside_action: TaskBoardOutsideWindowAction,
    timezone: &str,
    weekdays: Vec<TaskBoardPolicyWeekday>,
    start_time: &str,
    end_time: &str,
) -> TaskBoardPolicyWindow {
    TaskBoardPolicyWindow {
        scope: TaskBoardPolicyScope::Repository("example/compass".into()),
        timezone: timezone.into(),
        weekdays,
        start_time: start_time.into(),
        end_time: end_time.into(),
        outside_action,
    }
}

fn limit_policy() -> TaskBoardAutomationPolicy {
    TaskBoardAutomationPolicy {
        limits: vec![
            TaskBoardPolicyLimit::Concurrency {
                scope: TaskBoardPolicyScope::Repository(" example/compass ".into()),
                limit: 2,
                reservation: 1,
            },
            TaskBoardPolicyLimit::Rate {
                scope: TaskBoardPolicyScope::Workflow(TaskBoardWorkflowKind::DefaultTask),
                limit: 5,
                window_seconds: 60,
                reservation: 1,
            },
            TaskBoardPolicyLimit::TokenBudget {
                scope: TaskBoardPolicyScope::Global,
                limit: 10_000,
                window_seconds: 3_600,
            },
            TaskBoardPolicyLimit::MonetaryBudget {
                scope: TaskBoardPolicyScope::Repository("example/compass".into()),
                limit_microusd: 1_000_000,
                window_seconds: 86_400,
            },
            TaskBoardPolicyLimit::Concurrency {
                scope: TaskBoardPolicyScope::Repository("example/lantern".into()),
                limit: 1,
                reservation: 1,
            },
        ],
        windows: Vec::new(),
    }
}

#[test]
fn compiler_combines_matching_scopes_and_positive_integer_evidence() {
    let compiled = compile_task_board_policy(&limit_policy(), &context("2026-07-15T10:00:00Z"))
        .expect("compile policy");

    assert_eq!(compiled.requirements.len(), 4);
    assert_eq!(compiled.requirements[0].scope, "repository:example/compass");
    assert_eq!(compiled.requirements[1].scope, "workflow:default_task");
    let tokens = compiled
        .requirements
        .iter()
        .find(|requirement| requirement.kind == TaskBoardAdmissionRequirementKind::TokenBudget)
        .expect("token requirement");
    let money = compiled
        .requirements
        .iter()
        .find(|requirement| requirement.kind == TaskBoardAdmissionRequirementKind::MonetaryBudget)
        .expect("money requirement");
    assert_eq!(tokens.reservation, Some(400));
    assert_eq!(money.reservation, Some(75_000));
}

#[test]
fn token_and_microusd_evidence_must_be_present_and_positive() {
    let token_policy = TaskBoardAutomationPolicy {
        limits: vec![TaskBoardPolicyLimit::TokenBudget {
            scope: TaskBoardPolicyScope::Global,
            limit: 10_000,
            window_seconds: 3_600,
        }],
        windows: Vec::new(),
    };
    let mut token_context = context("2026-07-15T10:00:00Z");
    token_context.estimated_tokens = None;
    assert!(matches!(
        compile_task_board_policy(&token_policy, &token_context),
        Err(TaskBoardPolicyCompilationError::MissingTokenEvidence { .. })
    ));
    token_context.estimated_tokens = Some(0);
    assert!(matches!(
        compile_task_board_policy(&token_policy, &token_context),
        Err(TaskBoardPolicyCompilationError::InvalidTokenEvidence { .. })
    ));

    let money_policy = TaskBoardAutomationPolicy {
        limits: vec![TaskBoardPolicyLimit::MonetaryBudget {
            scope: TaskBoardPolicyScope::Global,
            limit_microusd: 1_000_000,
            window_seconds: 86_400,
        }],
        windows: Vec::new(),
    };
    let mut money_context = context("2026-07-15T10:00:00Z");
    money_context.estimated_cost_microusd = None;
    assert!(matches!(
        compile_task_board_policy(&money_policy, &money_context),
        Err(TaskBoardPolicyCompilationError::MissingCostEvidence { .. })
    ));
    money_context.estimated_cost_microusd = Some(0);
    assert!(matches!(
        compile_task_board_policy(&money_policy, &money_context),
        Err(TaskBoardPolicyCompilationError::InvalidCostEvidence { .. })
    ));
}

#[test]
fn whole_policy_validation_rejects_invalid_unmatched_rules() {
    let invalid_limit = TaskBoardAutomationPolicy {
        limits: vec![TaskBoardPolicyLimit::Rate {
            scope: TaskBoardPolicyScope::Repository("example/lantern".into()),
            limit: 5,
            window_seconds: 0,
            reservation: 1,
        }],
        windows: Vec::new(),
    };
    assert!(matches!(
        validate_task_board_policy(&invalid_limit),
        Err(TaskBoardPolicyCompilationError::InvalidLimit { .. })
    ));

    let invalid_window = TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![window(
            TaskBoardOutsideWindowAction::Deny,
            "Fictional/Clock",
            vec![TaskBoardPolicyWeekday::Monday],
            "09:00",
            "17:00",
        )],
    };

    assert!(matches!(
        validate_task_board_policy(&invalid_window),
        Err(TaskBoardPolicyCompilationError::InvalidTimezone { .. })
    ));
}

#[test]
fn whole_policy_rejects_conflicting_canonical_rules_independent_of_order() {
    let first = TaskBoardPolicyLimit::Concurrency {
        scope: TaskBoardPolicyScope::Repository(" Example/Compass ".into()),
        limit: 2,
        reservation: 1,
    };
    let second = TaskBoardPolicyLimit::Concurrency {
        scope: TaskBoardPolicyScope::Repository("example/compass".into()),
        limit: 3,
        reservation: 1,
    };
    let forward = TaskBoardAutomationPolicy {
        limits: vec![first.clone(), second.clone()],
        windows: Vec::new(),
    };
    let reverse = TaskBoardAutomationPolicy {
        limits: vec![second, first],
        windows: Vec::new(),
    };

    let forward_error = validate_task_board_policy(&forward).expect_err("conflicting policy");
    let reverse_error = validate_task_board_policy(&reverse).expect_err("conflicting policy");
    assert_eq!(forward_error, reverse_error);
    assert!(matches!(
        forward_error,
        TaskBoardPolicyCompilationError::ConflictingRule { .. }
    ));
}

#[test]
fn whole_policy_rejects_conflicting_window_actions() {
    let first = window(
        TaskBoardOutsideWindowAction::Defer,
        "Europe/Warsaw",
        vec![TaskBoardPolicyWeekday::Monday],
        "09:00",
        "17:00",
    );
    let mut conflict = first.clone();
    conflict.outside_action = TaskBoardOutsideWindowAction::Deny;
    let policy = TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![first, conflict],
    };

    assert!(matches!(
        validate_task_board_policy(&policy),
        Err(TaskBoardPolicyCompilationError::ConflictingRule { .. })
    ));
}

#[test]
fn exact_policy_duplicates_compile_once_with_stable_order() {
    let first = TaskBoardPolicyLimit::Rate {
        scope: TaskBoardPolicyScope::Global,
        limit: 10,
        window_seconds: 60,
        reservation: 1,
    };
    let duplicate = first.clone();
    let token = TaskBoardPolicyLimit::TokenBudget {
        scope: TaskBoardPolicyScope::Global,
        limit: 10_000,
        window_seconds: 3_600,
    };
    let forward = TaskBoardAutomationPolicy {
        limits: vec![token.clone(), first.clone(), duplicate],
        windows: Vec::new(),
    };
    let reverse = TaskBoardAutomationPolicy {
        limits: vec![first, token],
        windows: Vec::new(),
    };

    validate_task_board_policy(&forward).expect("exact duplicate is valid");
    let forward = compile_task_board_policy(&forward, &context("2026-07-15T10:00:00Z"))
        .expect("compile forward");
    let reverse = compile_task_board_policy(&reverse, &context("2026-07-15T10:00:00Z"))
        .expect("compile reverse");
    assert_eq!(forward, reverse);
    assert_eq!(forward.requirements.len(), 2);
}

#[test]
fn recurring_window_explicitly_defers_or_denies() {
    let deferred = TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![window(
            TaskBoardOutsideWindowAction::Defer,
            "Europe/Warsaw",
            vec![TaskBoardPolicyWeekday::Monday],
            "09:00",
            "17:00",
        )],
    };
    let denied = TaskBoardAutomationPolicy {
        windows: vec![window(
            TaskBoardOutsideWindowAction::Deny,
            "Europe/Warsaw",
            vec![TaskBoardPolicyWeekday::Monday],
            "09:00",
            "17:00",
        )],
        ..TaskBoardAutomationPolicy::default()
    };
    let context = context("2026-07-14T10:00:00Z");

    let deferred = evaluate_task_board_policy(&deferred, &context, Vec::new())
        .expect("evaluate deferred window");
    let denied =
        evaluate_task_board_policy(&denied, &context, Vec::new()).expect("evaluate denied window");
    assert_eq!(deferred.decision, TaskBoardAdmissionDecision::Deferred);
    assert_eq!(
        deferred.next_available_at.as_deref(),
        Some("2026-07-20T07:00:00Z")
    );
    assert_eq!(denied.decision, TaskBoardAdmissionDecision::Rejected);
    assert_eq!(
        denied.blockers[0].reason,
        TaskBoardAdmissionBlockReason::WindowClosed
    );
}

#[test]
fn ambiguous_fall_back_boundary_uses_the_later_fold() {
    let policy = TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![window(
            TaskBoardOutsideWindowAction::Deny,
            "America/New_York",
            vec![TaskBoardPolicyWeekday::Sunday],
            "01:00",
            "03:00",
        )],
    };
    let compiled = compile_task_board_policy(&policy, &context("2026-11-01T06:30:00Z"))
        .expect("compile fall-back window");
    assert_eq!(
        compiled.requirements[0].available_at.as_deref(),
        Some("2026-11-01T06:00:00Z")
    );
    assert_eq!(compiled.requirements[0].window_seconds, Some(7_200));
}

#[test]
fn nonexistent_spring_boundary_advances_to_first_valid_minute() {
    let policy = TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![window(
            TaskBoardOutsideWindowAction::Deny,
            "America/New_York",
            vec![TaskBoardPolicyWeekday::Sunday],
            "02:30",
            "04:00",
        )],
    };
    let compiled = compile_task_board_policy(&policy, &context("2026-03-08T07:30:00Z"))
        .expect("compile spring-forward window");
    assert_eq!(
        compiled.requirements[0].available_at.as_deref(),
        Some("2026-03-08T07:00:00Z")
    );
    assert_eq!(compiled.requirements[0].window_seconds, Some(3_600));
}

#[test]
fn overnight_window_uses_the_next_local_day() {
    let policy = TaskBoardAutomationPolicy {
        limits: Vec::new(),
        windows: vec![window(
            TaskBoardOutsideWindowAction::Deny,
            "Europe/Warsaw",
            vec![TaskBoardPolicyWeekday::Monday],
            "22:00",
            "02:00",
        )],
    };
    let evaluation =
        evaluate_task_board_policy(&policy, &context("2026-07-13T22:30:00Z"), Vec::new())
            .expect("evaluate overnight window");
    assert_eq!(evaluation.decision, TaskBoardAdmissionDecision::Allowed);
}
