use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use super::{
    MAX_CONDITIONS_PER_RULE, MAX_LABEL_CONDITION_ITEMS, MAX_STRING_CONDITION_BYTES,
    MAX_TRIAGE_RULES, TRIAGE_RULE_SET_SCHEMA_VERSION, TriageRule, TriageRuleCondition,
    TriageRuleSetV1, is_canonical_rule_id,
};
use crate::task_board::triage::{canonicalize_labels, is_canonical_bounded_text};
use crate::task_board::types::ExternalRefProvider;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "issue", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TriageRuleSetValidationIssue {
    UnsupportedSchemaVersion { expected: u16, actual: u16 },
    TooManyRules { max: usize, actual: usize },
    MalformedRuleId { index: usize },
    DuplicateRuleId { rule_id: String },
    TooManyConditions { rule_id: String, max: usize, actual: usize },
    MalformedCondition { rule_id: String, condition_index: usize },
    DuplicateSelector { rule_id: String, duplicate_of: String },
    SelfContradictoryRule { rule_id: String },
    ShadowedRule { rule_id: String, shadowed_by: String },
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TriageRuleSetValidationReport {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub issues: Vec<TriageRuleSetValidationIssue>,
}

impl TriageRuleSetValidationReport {
    #[must_use]
    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }
}

/// Validate an entire candidate rule set before it may become a draft or be
/// activated. Never mutates or consults live state -- a rejected candidate
/// leaves whatever is currently active completely untouched.
#[must_use]
pub fn validate_triage_rule_set(candidate: &TriageRuleSetV1) -> TriageRuleSetValidationReport {
    let mut issues = Vec::new();
    if candidate.schema_version != TRIAGE_RULE_SET_SCHEMA_VERSION {
        issues.push(TriageRuleSetValidationIssue::UnsupportedSchemaVersion {
            expected: TRIAGE_RULE_SET_SCHEMA_VERSION,
            actual: candidate.schema_version,
        });
        return TriageRuleSetValidationReport { issues };
    }
    if candidate.rules.len() > MAX_TRIAGE_RULES {
        issues.push(TriageRuleSetValidationIssue::TooManyRules {
            max: MAX_TRIAGE_RULES,
            actual: candidate.rules.len(),
        });
    }
    let mut seen_ids = HashSet::new();
    let mut accepted: Vec<(String, Vec<TriageRuleCondition>)> = Vec::new();
    for (index, rule) in candidate.rules.iter().enumerate() {
        if let Some(issue) = validate_single_rule(index, rule, &mut seen_ids, &mut accepted) {
            issues.push(issue);
        }
    }
    TriageRuleSetValidationReport { issues }
}

/// Validate one rule against the rules accepted so far, recording its
/// canonical selector in `accepted` when it passes. Split out of
/// `validate_triage_rule_set` to keep that function's cognitive complexity
/// within the crate's clippy threshold.
fn validate_single_rule(
    index: usize,
    rule: &TriageRule,
    seen_ids: &mut HashSet<String>,
    accepted: &mut Vec<(String, Vec<TriageRuleCondition>)>,
) -> Option<TriageRuleSetValidationIssue> {
    if !is_canonical_rule_id(&rule.id) {
        return Some(TriageRuleSetValidationIssue::MalformedRuleId { index });
    }
    if !seen_ids.insert(rule.id.clone()) {
        return Some(TriageRuleSetValidationIssue::DuplicateRuleId { rule_id: rule.id.clone() });
    }
    if rule.when.len() > MAX_CONDITIONS_PER_RULE {
        return Some(TriageRuleSetValidationIssue::TooManyConditions {
            rule_id: rule.id.clone(),
            max: MAX_CONDITIONS_PER_RULE,
            actual: rule.when.len(),
        });
    }
    if let Some(condition_index) = first_malformed_condition(&rule.when) {
        return Some(TriageRuleSetValidationIssue::MalformedCondition {
            rule_id: rule.id.clone(),
            condition_index,
        });
    }
    if is_self_contradictory(&rule.when) {
        return Some(TriageRuleSetValidationIssue::SelfContradictoryRule {
            rule_id: rule.id.clone(),
        });
    }
    let canonical = canonical_when(&rule.when);
    if let Some((earlier_id, _)) = accepted.iter().find(|(_, earlier)| *earlier == canonical) {
        return Some(TriageRuleSetValidationIssue::DuplicateSelector {
            rule_id: rule.id.clone(),
            duplicate_of: earlier_id.clone(),
        });
    }
    if let Some((earlier_id, _)) =
        accepted.iter().find(|(_, earlier)| is_subset(earlier, &canonical))
    {
        return Some(TriageRuleSetValidationIssue::ShadowedRule {
            rule_id: rule.id.clone(),
            shadowed_by: earlier_id.clone(),
        });
    }
    accepted.push((rule.id.clone(), canonical));
    None
}

fn first_malformed_condition(when: &[TriageRuleCondition]) -> Option<usize> {
    when.iter().position(|condition| !condition_is_well_formed(condition))
}

fn condition_is_well_formed(condition: &TriageRuleCondition) -> bool {
    match condition {
        TriageRuleCondition::LabelsHasAny { labels }
        | TriageRuleCondition::LabelsHasAll { labels }
        | TriageRuleCondition::LabelsHasNone { labels }
        | TriageRuleCondition::TargetProjectTypesHasAny { types: labels }
        | TriageRuleCondition::TargetProjectTypesHasNone { types: labels } => {
            well_formed_label_list(labels)
        }
        TriageRuleCondition::ExecutionRepositoryEquals { value }
        | TriageRuleCondition::ProjectIdEquals { value } => {
            is_canonical_bounded_text(value, MAX_STRING_CONDITION_BYTES)
        }
        TriageRuleCondition::PriorityEquals { .. }
        | TriageRuleCondition::ExecutionRepositoryIsPresent
        | TriageRuleCondition::ExecutionRepositoryIsMissing
        | TriageRuleCondition::ProjectIdIsPresent
        | TriageRuleCondition::ProjectIdIsMissing
        | TriageRuleCondition::ImportedFromProviderEquals { .. }
        | TriageRuleCondition::ImportedFromProviderIsMissing => true,
    }
}

fn well_formed_label_list(values: &[String]) -> bool {
    !values.is_empty()
        && values.len() <= MAX_LABEL_CONDITION_ITEMS
        && values
            .iter()
            .all(|value| is_canonical_bounded_text(value, MAX_STRING_CONDITION_BYTES))
}

/// Whether `when`, taken as a conjunction, can ever be satisfied by any
/// item. Sound but not complete: every reported contradiction is real, but
/// some exotic unsatisfiable combinations may slip through undetected.
fn is_self_contradictory(when: &[TriageRuleCondition]) -> bool {
    let mut priority = None;
    let mut execution_repository = PresenceConstraint::<String>::default();
    let mut project_id = PresenceConstraint::<String>::default();
    let mut provider = PresenceConstraint::<ExternalRefProvider>::default();
    let mut label_all: HashSet<String> = HashSet::new();
    let mut label_none: HashSet<String> = HashSet::new();
    let mut label_any_groups: Vec<HashSet<String>> = Vec::new();
    let mut type_none: HashSet<String> = HashSet::new();
    let mut type_any_groups: Vec<HashSet<String>> = Vec::new();
    for condition in when {
        let compatible = match condition {
            TriageRuleCondition::PriorityEquals { priority: value } => match priority {
                Some(existing) if existing != *value => false,
                _ => {
                    priority = Some(*value);
                    true
                }
            },
            TriageRuleCondition::ExecutionRepositoryEquals { value } => {
                execution_repository.merge_equals(value.clone())
            }
            TriageRuleCondition::ExecutionRepositoryIsPresent => execution_repository.merge_present(),
            TriageRuleCondition::ExecutionRepositoryIsMissing => execution_repository.merge_missing(),
            TriageRuleCondition::ProjectIdEquals { value } => project_id.merge_equals(value.clone()),
            TriageRuleCondition::ProjectIdIsPresent => project_id.merge_present(),
            TriageRuleCondition::ProjectIdIsMissing => project_id.merge_missing(),
            TriageRuleCondition::ImportedFromProviderEquals { provider: value } => {
                provider.merge_equals(*value)
            }
            TriageRuleCondition::ImportedFromProviderIsMissing => provider.merge_missing(),
            TriageRuleCondition::LabelsHasAll { labels } => {
                label_all.extend(canonicalize_labels(labels));
                true
            }
            TriageRuleCondition::LabelsHasNone { labels } => {
                label_none.extend(canonicalize_labels(labels));
                true
            }
            TriageRuleCondition::LabelsHasAny { labels } => {
                label_any_groups.push(canonicalize_labels(labels).into_iter().collect());
                true
            }
            TriageRuleCondition::TargetProjectTypesHasNone { types } => {
                type_none.extend(canonicalize_labels(types));
                true
            }
            TriageRuleCondition::TargetProjectTypesHasAny { types } => {
                type_any_groups.push(canonicalize_labels(types).into_iter().collect());
                true
            }
        };
        if !compatible {
            return true;
        }
    }
    if !label_all.is_disjoint(&label_none) {
        return true;
    }
    if label_any_groups
        .iter()
        .any(|group| group.iter().all(|item| label_none.contains(item)))
    {
        return true;
    }
    type_any_groups
        .iter()
        .any(|group| group.iter().all(|item| type_none.contains(item)))
}

#[derive(Default)]
enum PresenceConstraint<T> {
    #[default]
    Unconstrained,
    Present(Option<T>),
    Missing,
}

impl<T: PartialEq + Clone> PresenceConstraint<T> {
    fn merge_equals(&mut self, value: T) -> bool {
        match self {
            Self::Unconstrained | Self::Present(None) => {
                *self = Self::Present(Some(value));
                true
            }
            Self::Present(Some(existing)) => *existing == value,
            Self::Missing => false,
        }
    }

    fn merge_present(&mut self) -> bool {
        match self {
            Self::Unconstrained => {
                *self = Self::Present(None);
                true
            }
            Self::Present(_) => true,
            Self::Missing => false,
        }
    }

    fn merge_missing(&mut self) -> bool {
        match self {
            Self::Unconstrained => {
                *self = Self::Missing;
                true
            }
            Self::Missing => true,
            Self::Present(_) => false,
        }
    }
}

/// Canonicalize `when` into a stable, sorted, deduped form used to compare
/// two rules' selectors for identity or subset (shadowing) purposes,
/// independent of authoring order within the condition list itself.
fn canonical_when(when: &[TriageRuleCondition]) -> Vec<TriageRuleCondition> {
    let mut canonical: Vec<TriageRuleCondition> =
        when.iter().map(TriageRuleCondition::canonicalized).collect();
    canonical.sort_by_key(condition_sort_key);
    canonical.dedup();
    canonical
}

fn condition_sort_key(condition: &TriageRuleCondition) -> String {
    serde_json::to_string(condition).expect("TriageRuleCondition is always serializable")
}

/// Whether every condition in `earlier` also appears in `later` -- i.e.
/// whether any item satisfying `later` (all of its conditions) necessarily
/// already satisfies `earlier` too, so a rule shaped like `later` can never
/// fire once a rule shaped like `earlier` has already matched it.
fn is_subset(earlier: &[TriageRuleCondition], later: &[TriageRuleCondition]) -> bool {
    earlier.iter().all(|condition| later.contains(condition))
}

#[cfg(test)]
#[path = "validation_tests.rs"]
mod tests;
