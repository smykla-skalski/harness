use serde::{Deserialize, Serialize};

use super::triage::{TriageVerdict, canonicalize_labels, is_canonical_bounded_text};
use super::types::{ExternalRefProvider, TaskBoardItem, TaskBoardPriority};

pub mod store;
mod validation;

pub use store::{
    TriageRuleSetActivationResult, TriageRuleSetAuditEntry, TriageRuleSetAuditKind,
    TriageRuleSetDraft, TriageRuleSetDraftSaveResult, TriageRuleSetPreviewDiffEntry,
    TriageRuleSetPreviewResult, TriageRuleSetRevisionStatus, TriageRuleSetRevisionSummary,
};
pub use validation::{
    TriageRuleSetValidationIssue, TriageRuleSetValidationReport, validate_triage_rule_set,
};

/// Stable identity for the runtime-authored rule evaluator, as distinct from
/// [`super::triage::BUILTIN_V1_EVALUATOR_IDENTITY`]. `evaluator_version` for
/// this identity is always the activated rule set's revision number, so a
/// decision's `(evaluator_identity, evaluator_version)` pair alone traces it
/// back to the exact immutable rule set that produced it.
pub const RUNTIME_RULES_EVALUATOR_IDENTITY: &str = "task_board.triage.rules_v1";
pub const TRIAGE_RULE_SET_SCHEMA_VERSION: u16 = 1;

pub const MAX_TRIAGE_RULES: usize = 200;
pub const MAX_CONDITIONS_PER_RULE: usize = 16;
pub const MAX_RULE_ID_BYTES: usize = 128;
pub const MAX_LABEL_CONDITION_ITEMS: usize = 32;
pub const MAX_STRING_CONDITION_BYTES: usize = 256;

/// A durable, versioned, ordered candidate rule set. Authored order is
/// evaluation order (first matching rule wins) and is itself part of the
/// candidate's canonical, persisted identity -- reordering two rules is a
/// real change, not a no-op.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TriageRuleSetV1 {
    pub schema_version: u16,
    pub rules: Vec<TriageRule>,
    pub default_outcome: TriageRuleOutcome,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TriageRule {
    pub id: String,
    /// Conjunction (AND) of closed, typed predicates. Empty matches every
    /// eligible item -- a valid, if unusual, catch-all.
    #[serde(default)]
    pub when: Vec<TriageRuleCondition>,
    pub outcome: TriageRuleOutcome,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TriageRuleOutcome {
    pub verdict: TriageVerdict,
    #[serde(default)]
    pub priority_action: TriagePriorityAction,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TriagePriorityAction {
    #[default]
    Keep,
    SetTo {
        priority: TaskBoardPriority,
    },
}

/// The closed, typed condition vocabulary over stable Task Board facts.
/// Every eligible item is already a dispatchable `Task` in Inbox or Todo
/// (see `triage_eligible`), so `kind` carries no discriminating power here
/// and is deliberately not part of this vocabulary. Title and body are free
/// text and deliberately excluded too -- conditions are closed and typed,
/// never a regex or arbitrary expression over prose.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "fact", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TriageRuleCondition {
    LabelsHasAny { labels: Vec<String> },
    LabelsHasAll { labels: Vec<String> },
    LabelsHasNone { labels: Vec<String> },
    PriorityEquals { priority: TaskBoardPriority },
    ExecutionRepositoryEquals { value: String },
    ExecutionRepositoryIsPresent,
    ExecutionRepositoryIsMissing,
    ProjectIdEquals { value: String },
    ProjectIdIsPresent,
    ProjectIdIsMissing,
    TargetProjectTypesHasAny { types: Vec<String> },
    TargetProjectTypesHasNone { types: Vec<String> },
    ImportedFromProviderEquals { provider: ExternalRefProvider },
    ImportedFromProviderIsMissing,
}

impl TriageRuleCondition {
    /// Canonicalized for selector-identity comparison: label/type lists are
    /// case-folded, trimmed, deduped, and sorted, mirroring how the item's
    /// own labels are canonicalized before matching, so authoring order and
    /// case never change a condition's identity.
    #[must_use]
    fn canonicalized(&self) -> Self {
        match self {
            Self::LabelsHasAny { labels } => Self::LabelsHasAny {
                labels: canonicalize_labels(labels),
            },
            Self::LabelsHasAll { labels } => Self::LabelsHasAll {
                labels: canonicalize_labels(labels),
            },
            Self::LabelsHasNone { labels } => Self::LabelsHasNone {
                labels: canonicalize_labels(labels),
            },
            Self::TargetProjectTypesHasAny { types } => Self::TargetProjectTypesHasAny {
                types: canonicalize_labels(types),
            },
            Self::TargetProjectTypesHasNone { types } => Self::TargetProjectTypesHasNone {
                types: canonicalize_labels(types),
            },
            other => other.clone(),
        }
    }
}

#[must_use]
pub fn is_canonical_rule_id(value: &str) -> bool {
    is_canonical_bounded_text(value, MAX_RULE_ID_BYTES)
}

/// Which rule (or the rule set's default) decided an item's outcome, for
/// tracing and preview diffs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TriageRuleMatch {
    Rule(String),
    Default,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TriageRuleEvaluation {
    pub matched: TriageRuleMatch,
    pub verdict: TriageVerdict,
    pub priority_action: TriagePriorityAction,
}

/// Evaluate a validated `TriageRuleSetV1` against one item's current facts.
/// Rules are tried in authored order; the first whose conditions all hold
/// wins. Callers are responsible for the same eligibility gate `BuiltInV1`
/// uses -- this only decides the verdict for an already-eligible item.
///
/// Re-canonicalizes each condition's needle list on every call (see
/// `has_any`/`has_all`), so a bulk reevaluation over many items redoes that
/// work once per item per condition rather than once per activation. This
/// is a deliberate trade against a caller-side "canonicalize once at load"
/// cache: the same rule set is also evaluated with a caller-supplied,
/// not-yet-persisted candidate during preview, and centralizing
/// canonicalization here keeps every caller correct by construction instead
/// of relying on each one to canonicalize first. Rule/condition/label counts
/// are bounded (`MAX_TRIAGE_RULES`, `MAX_CONDITIONS_PER_RULE`,
/// `MAX_LABEL_CONDITION_ITEMS`) and reevaluation only runs over eligible
/// items, so this has not shown up as a real cost; revisit if it does.
#[must_use]
pub fn evaluate_triage_rule_set(rule_set: &TriageRuleSetV1, item: &TaskBoardItem) -> TriageRuleEvaluation {
    let facts = ItemFacts::from_item(item);
    for rule in &rule_set.rules {
        if rule.when.iter().all(|condition| facts.satisfies(condition)) {
            return TriageRuleEvaluation {
                matched: TriageRuleMatch::Rule(rule.id.clone()),
                verdict: rule.outcome.verdict,
                priority_action: rule.outcome.priority_action,
            };
        }
    }
    TriageRuleEvaluation {
        matched: TriageRuleMatch::Default,
        verdict: rule_set.default_outcome.verdict,
        priority_action: rule_set.default_outcome.priority_action,
    }
}

struct ItemFacts {
    labels: Vec<String>,
    priority: TaskBoardPriority,
    execution_repository: Option<String>,
    project_id: Option<String>,
    target_project_types: Vec<String>,
    imported_from_provider: Option<ExternalRefProvider>,
}

impl ItemFacts {
    fn from_item(item: &TaskBoardItem) -> Self {
        Self {
            labels: canonicalize_labels(&item.tags),
            priority: item.priority,
            execution_repository: item.execution_repository.clone(),
            project_id: item.project_id.clone(),
            target_project_types: canonicalize_labels(&item.target_project_types),
            imported_from_provider: item.imported_from_provider,
        }
    }

    fn satisfies(&self, condition: &TriageRuleCondition) -> bool {
        match condition {
            TriageRuleCondition::LabelsHasAny { labels } => {
                has_any(&self.labels, labels)
            }
            TriageRuleCondition::LabelsHasAll { labels } => has_all(&self.labels, labels),
            TriageRuleCondition::LabelsHasNone { labels } => !has_any(&self.labels, labels),
            TriageRuleCondition::PriorityEquals { priority } => self.priority == *priority,
            TriageRuleCondition::ExecutionRepositoryEquals { value } => {
                self.execution_repository.as_deref() == Some(value.as_str())
            }
            TriageRuleCondition::ExecutionRepositoryIsPresent => self.execution_repository.is_some(),
            TriageRuleCondition::ExecutionRepositoryIsMissing => self.execution_repository.is_none(),
            TriageRuleCondition::ProjectIdEquals { value } => {
                self.project_id.as_deref() == Some(value.as_str())
            }
            TriageRuleCondition::ProjectIdIsPresent => self.project_id.is_some(),
            TriageRuleCondition::ProjectIdIsMissing => self.project_id.is_none(),
            TriageRuleCondition::TargetProjectTypesHasAny { types } => {
                has_any(&self.target_project_types, types)
            }
            TriageRuleCondition::TargetProjectTypesHasNone { types } => {
                !has_any(&self.target_project_types, types)
            }
            TriageRuleCondition::ImportedFromProviderEquals { provider } => {
                self.imported_from_provider == Some(*provider)
            }
            TriageRuleCondition::ImportedFromProviderIsMissing => {
                self.imported_from_provider.is_none()
            }
        }
    }
}

fn has_any(haystack: &[String], needles: &[String]) -> bool {
    let needles = canonicalize_labels(needles);
    needles.iter().any(|needle| haystack.contains(needle))
}

fn has_all(haystack: &[String], needles: &[String]) -> bool {
    let needles = canonicalize_labels(needles);
    needles.iter().all(|needle| haystack.contains(needle))
}

#[cfg(test)]
#[path = "triage_rules_tests.rs"]
mod tests;
