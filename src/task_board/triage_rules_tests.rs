use super::*;

fn blank_item() -> TaskBoardItem {
    TaskBoardItem::new(
        "item-1".into(),
        "Title".into(),
        "Body".into(),
        "2026-07-24T00:00:00Z".into(),
    )
}

fn item_with(tags: &[&str], priority: TaskBoardPriority) -> TaskBoardItem {
    let mut item = blank_item();
    item.tags = tags.iter().map(|tag| (*tag).to_string()).collect();
    item.priority = priority;
    item
}

fn rule(id: &str, when: Vec<TriageRuleCondition>, verdict: TriageVerdict) -> TriageRule {
    TriageRule {
        id: id.to_string(),
        when,
        outcome: TriageRuleOutcome {
            verdict,
            priority_action: TriagePriorityAction::Keep,
        },
    }
}

fn default_undecided() -> TriageRuleOutcome {
    TriageRuleOutcome {
        verdict: TriageVerdict::Undecided,
        priority_action: TriagePriorityAction::Keep,
    }
}

#[test]
fn first_matching_rule_in_authored_order_wins() {
    let rule_set = TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![
            rule(
                "urgent",
                vec![TriageRuleCondition::PriorityEquals {
                    priority: TaskBoardPriority::Critical,
                }],
                TriageVerdict::Todo,
            ),
            rule(
                "bug",
                vec![TriageRuleCondition::LabelsHasAny {
                    labels: vec!["bug".to_string()],
                }],
                TriageVerdict::Todo,
            ),
        ],
        default_outcome: default_undecided(),
    };
    let item = item_with(&["bug"], TaskBoardPriority::Critical);
    let evaluation = evaluate_triage_rule_set(&rule_set, &item);
    assert_eq!(evaluation.matched, TriageRuleMatch::Rule("urgent".to_string()));
    assert_eq!(evaluation.verdict, TriageVerdict::Todo);
}

#[test]
fn no_matching_rule_falls_back_to_default_outcome() {
    let rule_set = TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![rule(
            "bug",
            vec![TriageRuleCondition::LabelsHasAny {
                labels: vec!["bug".to_string()],
            }],
            TriageVerdict::Todo,
        )],
        default_outcome: default_undecided(),
    };
    let item = item_with(&["chore"], TaskBoardPriority::Medium);
    let evaluation = evaluate_triage_rule_set(&rule_set, &item);
    assert_eq!(evaluation.matched, TriageRuleMatch::Default);
    assert_eq!(evaluation.verdict, TriageVerdict::Undecided);
}

#[test]
fn label_conditions_are_case_and_order_insensitive() {
    let rule_set = TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![rule(
            "bug",
            vec![TriageRuleCondition::LabelsHasAll {
                labels: vec!["Bug".to_string(), "P1".to_string()],
            }],
            TriageVerdict::Todo,
        )],
        default_outcome: default_undecided(),
    };
    let item = item_with(&["p1", "BUG", "extra"], TaskBoardPriority::Medium);
    let evaluation = evaluate_triage_rule_set(&rule_set, &item);
    assert_eq!(evaluation.matched, TriageRuleMatch::Rule("bug".to_string()));
}

#[test]
fn priority_action_set_to_is_reported_on_the_evaluation() {
    let rule_set = TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![TriageRule {
            id: "escalate".to_string(),
            when: vec![TriageRuleCondition::LabelsHasAny {
                labels: vec!["hot".to_string()],
            }],
            outcome: TriageRuleOutcome {
                verdict: TriageVerdict::Todo,
                priority_action: TriagePriorityAction::SetTo {
                    priority: TaskBoardPriority::Critical,
                },
            },
        }],
        default_outcome: default_undecided(),
    };
    let item = item_with(&["hot"], TaskBoardPriority::Low);
    let evaluation = evaluate_triage_rule_set(&rule_set, &item);
    assert_eq!(
        evaluation.priority_action,
        TriagePriorityAction::SetTo {
            priority: TaskBoardPriority::Critical
        }
    );
}

#[test]
fn optional_fact_conditions_match_presence_and_equality() {
    let rule_set = TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules: vec![rule(
            "repo",
            vec![
                TriageRuleCondition::ExecutionRepositoryEquals {
                    value: "owner/repo".to_string(),
                },
                TriageRuleCondition::ProjectIdIsMissing,
            ],
            TriageVerdict::Todo,
        )],
        default_outcome: default_undecided(),
    };
    let mut item = blank_item();
    item.execution_repository = Some("owner/repo".to_string());
    let evaluation = evaluate_triage_rule_set(&rule_set, &item);
    assert_eq!(evaluation.matched, TriageRuleMatch::Rule("repo".to_string()));

    item.project_id = Some("some-project".to_string());
    let evaluation = evaluate_triage_rule_set(&rule_set, &item);
    assert_eq!(evaluation.matched, TriageRuleMatch::Default);
}

#[test]
fn is_canonical_rule_id_rejects_empty_and_control_characters() {
    assert!(is_canonical_rule_id("bug-triage"));
    assert!(!is_canonical_rule_id(""));
    assert!(!is_canonical_rule_id("   "));
    assert!(!is_canonical_rule_id("bad\u{0007}id"));
}
