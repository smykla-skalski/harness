use super::*;
use crate::task_board::triage::TriageVerdict;
use crate::task_board::triage_rules::{TriagePriorityAction, TriageRule, TriageRuleOutcome};
use crate::task_board::types::TaskBoardPriority;

fn outcome(verdict: TriageVerdict) -> TriageRuleOutcome {
    TriageRuleOutcome {
        verdict,
        priority_action: TriagePriorityAction::Keep,
    }
}

fn rule(id: &str, when: Vec<TriageRuleCondition>) -> TriageRule {
    TriageRule {
        id: id.to_string(),
        when,
        outcome: outcome(TriageVerdict::Todo),
    }
}

fn candidate(rules: Vec<TriageRule>) -> TriageRuleSetV1 {
    TriageRuleSetV1 {
        schema_version: TRIAGE_RULE_SET_SCHEMA_VERSION,
        rules,
        default_outcome: outcome(TriageVerdict::Undecided),
    }
}

fn labels(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn empty_rule_set_is_valid() {
    let report = validate_triage_rule_set(&candidate(Vec::new()));
    assert!(report.is_valid());
}

#[test]
fn unsupported_schema_version_is_the_only_reported_issue() {
    let mut set = candidate(Vec::new());
    set.schema_version = 99;
    let report = validate_triage_rule_set(&set);
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::UnsupportedSchemaVersion {
            expected: TRIAGE_RULE_SET_SCHEMA_VERSION,
            actual: 99,
        }]
    );
}

#[test]
fn malformed_rule_id_is_rejected() {
    let report = validate_triage_rule_set(&candidate(vec![rule("  ", Vec::new())]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::MalformedRuleId { index: 0 }]
    );
}

#[test]
fn duplicate_rule_id_is_rejected() {
    let report = validate_triage_rule_set(&candidate(vec![
        rule(
            "dup",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["a"]) }],
        ),
        rule(
            "dup",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["b"]) }],
        ),
    ]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::DuplicateRuleId {
            rule_id: "dup".to_string()
        }]
    );
}

#[test]
fn empty_label_list_is_a_malformed_condition() {
    let report = validate_triage_rule_set(&candidate(vec![rule(
        "empty-labels",
        vec![TriageRuleCondition::LabelsHasAny { labels: Vec::new() }],
    )]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::MalformedCondition {
            rule_id: "empty-labels".to_string(),
            condition_index: 0,
        }]
    );
}

#[test]
fn duplicate_canonical_selector_is_rejected_independent_of_authoring_order_and_case() {
    let report = validate_triage_rule_set(&candidate(vec![
        rule(
            "first",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["Bug", "P1"]) }],
        ),
        rule(
            "second",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["p1", "bug"]) }],
        ),
    ]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::DuplicateSelector {
            rule_id: "second".to_string(),
            duplicate_of: "first".to_string(),
        }]
    );
}

#[test]
fn contradictory_priority_equals_conditions_are_self_contradictory() {
    let report = validate_triage_rule_set(&candidate(vec![rule(
        "impossible",
        vec![
            TriageRuleCondition::PriorityEquals {
                priority: TaskBoardPriority::Low,
            },
            TriageRuleCondition::PriorityEquals {
                priority: TaskBoardPriority::High,
            },
        ],
    )]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::SelfContradictoryRule {
            rule_id: "impossible".to_string()
        }]
    );
}

#[test]
fn is_present_and_is_missing_on_the_same_fact_is_self_contradictory() {
    let report = validate_triage_rule_set(&candidate(vec![rule(
        "impossible",
        vec![
            TriageRuleCondition::ProjectIdIsPresent,
            TriageRuleCondition::ProjectIdIsMissing,
        ],
    )]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::SelfContradictoryRule {
            rule_id: "impossible".to_string()
        }]
    );
}

#[test]
fn requiring_and_excluding_the_same_label_is_self_contradictory() {
    let report = validate_triage_rule_set(&candidate(vec![rule(
        "impossible",
        vec![
            TriageRuleCondition::LabelsHasAll { labels: labels(&["bug"]) },
            TriageRuleCondition::LabelsHasNone { labels: labels(&["bug"]) },
        ],
    )]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::SelfContradictoryRule {
            rule_id: "impossible".to_string()
        }]
    );
}

#[test]
fn has_any_fully_excluded_by_has_none_is_self_contradictory() {
    let report = validate_triage_rule_set(&candidate(vec![rule(
        "impossible",
        vec![
            TriageRuleCondition::LabelsHasAny { labels: labels(&["bug", "chore"]) },
            TriageRuleCondition::LabelsHasNone { labels: labels(&["bug", "chore", "extra"]) },
        ],
    )]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::SelfContradictoryRule {
            rule_id: "impossible".to_string()
        }]
    );
}

#[test]
fn partial_label_overlap_between_has_any_and_has_none_is_not_a_contradiction() {
    let report = validate_triage_rule_set(&candidate(vec![rule(
        "fine",
        vec![
            TriageRuleCondition::LabelsHasAny { labels: labels(&["bug", "chore"]) },
            TriageRuleCondition::LabelsHasNone { labels: labels(&["chore"]) },
        ],
    )]));
    assert!(report.is_valid());
}

#[test]
fn a_catch_all_rule_shadows_every_later_rule() {
    let report = validate_triage_rule_set(&candidate(vec![
        rule("catch-all", Vec::new()),
        rule(
            "unreachable",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["bug"]) }],
        ),
    ]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::ShadowedRule {
            rule_id: "unreachable".to_string(),
            shadowed_by: "catch-all".to_string(),
        }]
    );
}

#[test]
fn a_strict_superset_of_an_earlier_rule_is_shadowed() {
    let report = validate_triage_rule_set(&candidate(vec![
        rule(
            "broad",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["bug"]) }],
        ),
        rule(
            "narrower",
            vec![
                TriageRuleCondition::LabelsHasAny { labels: labels(&["bug"]) },
                TriageRuleCondition::PriorityEquals {
                    priority: TaskBoardPriority::Critical,
                },
            ],
        ),
    ]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::ShadowedRule {
            rule_id: "narrower".to_string(),
            shadowed_by: "broad".to_string(),
        }]
    );
}

#[test]
fn partially_overlapping_rules_are_not_shadowed_first_match_is_intentional_precedence() {
    let report = validate_triage_rule_set(&candidate(vec![
        rule(
            "critical-anything",
            vec![TriageRuleCondition::PriorityEquals {
                priority: TaskBoardPriority::Critical,
            }],
        ),
        rule(
            "bug-anything",
            vec![TriageRuleCondition::LabelsHasAny { labels: labels(&["bug"]) }],
        ),
    ]));
    assert!(report.is_valid());
}

#[test]
fn too_many_conditions_on_one_rule_is_rejected() {
    let when = (0..MAX_CONDITIONS_PER_RULE + 1)
        .map(|_| TriageRuleCondition::ExecutionRepositoryIsPresent)
        .collect::<Vec<_>>();
    let report = validate_triage_rule_set(&candidate(vec![rule("too-many", when)]));
    assert_eq!(
        report.issues,
        vec![TriageRuleSetValidationIssue::TooManyConditions {
            rule_id: "too-many".to_string(),
            max: MAX_CONDITIONS_PER_RULE,
            actual: MAX_CONDITIONS_PER_RULE + 1,
        }]
    );
}
