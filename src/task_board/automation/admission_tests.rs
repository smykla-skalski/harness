use super::*;

fn requirement(
    kind: TaskBoardAdmissionRequirementKind,
    scope: &str,
    limit: u64,
    window_seconds: Option<u64>,
    reservation: u64,
) -> TaskBoardAdmissionRequirement {
    TaskBoardAdmissionRequirement {
        kind,
        scope: scope.to_owned(),
        limit,
        window_seconds,
        reservation: Some(reservation),
        available_at: None,
    }
}

fn usage(
    kind: TaskBoardAdmissionRequirementKind,
    scope: &str,
    consumed: u64,
    window_seconds: Option<u64>,
    available_at: Option<&str>,
) -> TaskBoardAdmissionUsage {
    TaskBoardAdmissionUsage {
        kind,
        scope: scope.to_owned(),
        consumed,
        window_seconds,
        available_at: available_at.map(str::to_owned),
    }
}

#[test]
fn collection_is_stable_and_exposes_a_canonical_key() {
    let concurrency = requirement(
        TaskBoardAdmissionRequirementKind::Concurrency,
        " repository:sample/widgets ",
        2,
        None,
        1,
    );
    let tokens = requirement(
        TaskBoardAdmissionRequirementKind::TokenBudget,
        "workflow:default_task",
        10_000,
        Some(3_600),
        500,
    );

    let forward = collect_admission_requirements([tokens.clone(), concurrency.clone()])
        .expect("collect forward");
    let reverse = collect_admission_requirements([concurrency, tokens]).expect("collect reverse");

    assert_eq!(forward, reverse);
    assert_eq!(forward[0].scope, "repository:sample/widgets");
    let key = canonical_admission_requirement_key(&forward[0]).expect("canonical key");
    assert_eq!(key.kind, TaskBoardAdmissionRequirementKind::Concurrency);
    assert_eq!(key.scope, "repository:sample/widgets");
    assert_eq!(key.window_seconds, None);
    assert_eq!(key.window_starts_at, None);
    assert_eq!(
        key.stable_id(),
        "admission:v1:concurrency:25:repository:sample/widgets:-:-"
    );
}

#[test]
fn identical_requirements_deduplicate_but_key_conflicts_are_rejected() {
    let first = requirement(
        TaskBoardAdmissionRequirementKind::Rate,
        "global",
        5,
        Some(60),
        1,
    );
    let duplicate = first.clone();
    let mut conflict = first.clone();
    conflict.limit = 6;

    assert_eq!(
        collect_admission_requirements([first.clone(), duplicate])
            .expect("deduplicate exact requirement"),
        vec![first.clone()]
    );
    let forward = collect_admission_requirements([first.clone(), conflict.clone()]);
    let reverse = collect_admission_requirements([conflict, first]);
    assert_eq!(forward, reverse);
    assert!(matches!(
        forward,
        Err(TaskBoardAdmissionError::ConflictingRequirement { .. })
    ));
}

#[test]
fn all_five_requirement_kinds_allow_with_capacity() {
    let mut time_window = requirement(
        TaskBoardAdmissionRequirementKind::TimeWindow,
        "workflow:maintenance",
        1,
        Some(7_200),
        1,
    );
    time_window.available_at = Some("2026-07-15T08:00:00+02:00".into());
    let requirements = vec![
        requirement(
            TaskBoardAdmissionRequirementKind::Concurrency,
            "repository:sample/widgets",
            2,
            None,
            1,
        ),
        requirement(
            TaskBoardAdmissionRequirementKind::Rate,
            "global",
            10,
            Some(60),
            1,
        ),
        time_window,
        requirement(
            TaskBoardAdmissionRequirementKind::TokenBudget,
            "workflow:default_task",
            10_000,
            Some(3_600),
            500,
        ),
        requirement(
            TaskBoardAdmissionRequirementKind::MonetaryBudget,
            "global",
            2_000_000,
            Some(86_400),
            125_000,
        ),
    ];
    let usage = vec![
        usage(
            TaskBoardAdmissionRequirementKind::Concurrency,
            "repository:sample/widgets",
            1,
            None,
            None,
        ),
        usage(
            TaskBoardAdmissionRequirementKind::Rate,
            "global",
            4,
            Some(60),
            Some("2026-07-15T06:31:00Z"),
        ),
        usage(
            TaskBoardAdmissionRequirementKind::TokenBudget,
            "workflow:default_task",
            4_000,
            Some(3_600),
            Some("2026-07-15T07:00:00Z"),
        ),
        usage(
            TaskBoardAdmissionRequirementKind::MonetaryBudget,
            "global",
            500_000,
            Some(86_400),
            Some("2026-07-16T06:00:00Z"),
        ),
    ];

    let result = evaluate_admission_requirements(requirements, usage, "2026-07-15T06:30:00Z")
        .expect("evaluate admission");

    assert_eq!(result.decision, TaskBoardAdmissionDecision::Allowed);
    assert_eq!(result.requirements.len(), 5);
    assert!(result.blockers.is_empty());
}

#[test]
fn capacity_uses_checked_arithmetic_and_exact_deferral_boundaries() {
    let rate = requirement(
        TaskBoardAdmissionRequirementKind::Rate,
        "global",
        u64::MAX,
        Some(60),
        1,
    );
    let overflow = evaluate_admission_requirements(
        [rate],
        [usage(
            TaskBoardAdmissionRequirementKind::Rate,
            "global",
            u64::MAX,
            Some(60),
            Some("2026-07-15T06:01:00Z"),
        )],
        "2026-07-15T06:00:00Z",
    )
    .expect("overflow is a deterministic decision");
    assert_eq!(overflow.decision, TaskBoardAdmissionDecision::Rejected);
    assert_eq!(
        overflow.blockers[0].reason,
        TaskBoardAdmissionBlockReason::ArithmeticOverflow
    );

    let concurrency = requirement(
        TaskBoardAdmissionRequirementKind::Concurrency,
        "global",
        1,
        None,
        1,
    );
    let deferred = evaluate_admission_requirements(
        [concurrency],
        [usage(
            TaskBoardAdmissionRequirementKind::Concurrency,
            "global",
            1,
            None,
            Some("2026-07-15T06:02:00Z"),
        )],
        "2026-07-15T06:00:00Z",
    )
    .expect("capacity deferral");
    assert_eq!(deferred.decision, TaskBoardAdmissionDecision::Deferred);
    assert_eq!(
        deferred.next_available_at.as_deref(),
        Some("2026-07-15T06:02:00Z")
    );
}

#[test]
fn time_windows_are_half_open() {
    let mut window = requirement(
        TaskBoardAdmissionRequirementKind::TimeWindow,
        "global",
        1,
        Some(3_600),
        1,
    );
    window.available_at = Some("2026-07-15T06:00:00Z".into());

    let at_start =
        evaluate_admission_requirements([window.clone()], Vec::new(), "2026-07-15T06:00:00Z")
            .expect("start is included");
    let at_end = evaluate_admission_requirements([window], Vec::new(), "2026-07-15T07:00:00Z")
        .expect("end is excluded");

    assert_eq!(at_start.decision, TaskBoardAdmissionDecision::Allowed);
    assert_eq!(at_end.decision, TaskBoardAdmissionDecision::Rejected);
    assert_eq!(
        at_end.blockers[0].reason,
        TaskBoardAdmissionBlockReason::WindowClosed
    );
}

#[test]
fn missing_or_conflicting_usage_fails_closed() {
    let tokens = requirement(
        TaskBoardAdmissionRequirementKind::TokenBudget,
        "global",
        1_000,
        Some(3_600),
        100,
    );
    let missing =
        evaluate_admission_requirements([tokens.clone()], Vec::new(), "2026-07-15T06:00:00Z")
            .expect("missing usage is a decision");
    assert_eq!(missing.decision, TaskBoardAdmissionDecision::Rejected);
    assert_eq!(
        missing.blockers[0].reason,
        TaskBoardAdmissionBlockReason::MissingUsage
    );

    let first = usage(
        TaskBoardAdmissionRequirementKind::TokenBudget,
        "global",
        0,
        Some(3_600),
        Some("2026-07-15T07:00:00Z"),
    );
    let mut second = first.clone();
    second.consumed = 1;
    assert!(matches!(
        evaluate_admission_requirements([tokens], [first, second], "2026-07-15T06:00:00Z"),
        Err(TaskBoardAdmissionError::ConflictingUsage { .. })
    ));
}
