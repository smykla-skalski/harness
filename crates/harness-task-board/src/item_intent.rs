//! Pull request intent carried by a task-board ticket.
//!
//! `TaskBoardWorkflowKind` doubles as the ticket's execution-routing axis
//! (`is_write` picks headless-write vs read-only dispatch) and, for pull
//! request work, its provenance: a dependency update, a review request, or
//! both at once. A ticket that carries both intents is a distinct
//! `PrFixReview` kind rather than a collapse to one category, so it keeps every
//! reason it entered the board.
//!
//! The kind stays a flat `snake_case` string enum so it round-trips through the
//! existing derive-based serde, `OpenAPI` schema, and Swift codegen unchanged:
//! `pr_fix` and `pr_review` keep their meaning and the both-intents state is
//! the single new value `pr_fix_review`. No storage migration is required.

use serde::{Deserialize, Serialize};

use crate::types::AgentMode;

/// The reasons a pull request ticket exists, held as an intent set so a single
/// ticket can carry a dependency update, a review request, or both.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct PrIntentSet(u8);

impl PrIntentSet {
    const DEPENDENCY_UPDATE_BIT: u8 = 0b01;
    const REVIEW_REQUEST_BIT: u8 = 0b10;

    /// A Renovate, Dependabot, or dependency-labelled update.
    pub const DEPENDENCY_UPDATE: Self = Self(Self::DEPENDENCY_UPDATE_BIT);
    /// A pull request requesting the authenticated user as reviewer.
    pub const REVIEW_REQUEST: Self = Self(Self::REVIEW_REQUEST_BIT);
    /// Both intents on one pull request.
    pub const DEPENDENCY_AND_REVIEW: Self =
        Self(Self::DEPENDENCY_UPDATE_BIT | Self::REVIEW_REQUEST_BIT);

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The union of two intent sets.
    #[must_use]
    pub const fn with(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    #[must_use]
    pub const fn has_dependency_update(self) -> bool {
        self.contains(Self::DEPENDENCY_UPDATE)
    }

    #[must_use]
    pub const fn has_review_request(self) -> bool {
        self.contains(Self::REVIEW_REQUEST)
    }
}

/// The workflow routing kind for a ticket. The three `Pr*` variants record
/// which pull request intents put the ticket on the board.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardWorkflowKind {
    /// An unrecognized or not-yet-classified kind; dispatched read-only.
    Unknown,
    /// A plain unit of work an agent runs headless with write side effects.
    #[default]
    DefaultTask,
    /// A dependency-update pull request; routes as a write.
    PrFix,
    /// A review-request pull request; routes read-only.
    PrReview,
    /// A pull request that is both a dependency update and a review request.
    PrFixReview,
    /// A completed unit projected as a review; read-only.
    Review,
}

impl TaskBoardWorkflowKind {
    /// A dependency-update pull request.
    pub const PR_FIX: Self = Self::PrFix;
    /// A review-request pull request.
    pub const PR_REVIEW: Self = Self::PrReview;
    /// A pull request that is both a dependency update and a review request.
    pub const PR_FIX_REVIEW: Self = Self::PrFixReview;

    /// Write workflows perform publishing side effects, so they require
    /// Headless dispatch and configured publication automation; other kinds are
    /// read-only. A dependency-update pull request writes even when it also
    /// carries a review request.
    #[must_use]
    pub const fn is_write(self) -> bool {
        matches!(self, Self::DefaultTask | Self::PrFix | Self::PrFixReview)
    }

    #[must_use]
    pub const fn is_pull_request(self) -> bool {
        matches!(self, Self::PrFix | Self::PrReview | Self::PrFixReview)
    }

    /// The pull request intents this ticket carries, or `None` when it is not
    /// pull request work. Lets a client select the workflow from structured
    /// state instead of parsing the title or labels.
    #[must_use]
    pub const fn pr_intents(self) -> Option<PrIntentSet> {
        match self {
            Self::PrFix => Some(PrIntentSet::DEPENDENCY_UPDATE),
            Self::PrReview => Some(PrIntentSet::REVIEW_REQUEST),
            Self::PrFixReview => Some(PrIntentSet::DEPENDENCY_AND_REVIEW),
            _ => None,
        }
    }

    /// The pull request kind carrying an intent set. Empty or unmatched sets map
    /// to `DefaultTask`.
    #[must_use]
    pub const fn from_pr_intents(intents: PrIntentSet) -> Self {
        match (
            intents.has_dependency_update(),
            intents.has_review_request(),
        ) {
            (true, true) => Self::PrFixReview,
            (true, false) => Self::PrFix,
            (false, true) => Self::PrReview,
            (false, false) => Self::DefaultTask,
        }
    }

    /// Merge two kinds by unioning their pull request intents, so a pull request
    /// discovered as both a dependency update and a review request becomes one
    /// `PrFixReview` ticket. A ticket imported before intent classification
    /// (`DefaultTask`/`Unknown`) adopts the pull request kind discovery now
    /// reports, so a refresh backfills intent onto already-imported tickets; a
    /// terminal `Review` projection keeps its kind, and a non-pull-request
    /// `other` leaves `self` unchanged.
    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        if let Some(theirs) = other.pr_intents() {
            if let Some(mine) = self.pr_intents() {
                return Self::from_pr_intents(mine.with(theirs));
            }
            if matches!(self, Self::DefaultTask | Self::Unknown) {
                return other;
            }
        }
        self
    }

    #[must_use]
    pub const fn has_dependency_update_intent(self) -> bool {
        matches!(self, Self::PrFix | Self::PrFixReview)
    }

    #[must_use]
    pub const fn has_review_request_intent(self) -> bool {
        matches!(self, Self::PrReview | Self::PrFixReview)
    }

    /// A pure review-request pull request, which routes read-only. A pull
    /// request that also carries a dependency update (`PrFixReview`) is a write
    /// workflow (`is_write` is true) and routes through the write path, so it is
    /// deliberately excluded here even though it carries a review intent. Read-
    /// only dispatch, launch, head-freezing, and publication/evaluation gates
    /// must use this rather than `has_review_request_intent` to avoid pulling a
    /// both-intents ticket down a read-only path.
    #[must_use]
    pub const fn is_read_only_review(self) -> bool {
        matches!(self, Self::PrReview)
    }

    /// The agent mode an imported pull-request ticket adopts when it is admitted
    /// to Todo, derived from the intents the import carried. A pure review
    /// request routes read-only, so it runs in `Evaluate`; a dependency update -
    /// alone or combined with a review in one `PrFixReview` ticket - performs
    /// publishing side effects, so it runs headless with write access. Every
    /// non-pull-request kind returns `None`, leaving the item's own mode
    /// untouched. Admission uses this so moving an imported ticket from Inbox to
    /// Todo no longer leaves a review carrying the write-oriented default that
    /// read-only preparation later rejects.
    #[must_use]
    pub const fn imported_admission_agent_mode(self) -> Option<AgentMode> {
        match self {
            Self::PrReview => Some(AgentMode::Evaluate),
            Self::PrFix | Self::PrFixReview => Some(AgentMode::Headless),
            _ => None,
        }
    }

    /// The `snake_case` wire value, matching the derived serde representation.
    #[must_use]
    pub const fn as_wire_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::DefaultTask => "default_task",
            Self::PrFix => "pr_fix",
            Self::PrReview => "pr_review",
            Self::PrFixReview => "pr_fix_review",
            Self::Review => "review",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_write_matches_historical_routing() {
        assert!(TaskBoardWorkflowKind::DefaultTask.is_write());
        assert!(TaskBoardWorkflowKind::PrFix.is_write());
        assert!(!TaskBoardWorkflowKind::PrReview.is_write());
        assert!(!TaskBoardWorkflowKind::Review.is_write());
        assert!(!TaskBoardWorkflowKind::Unknown.is_write());
        // A pull request that is both keeps write routing via its dependency
        // update.
        assert!(TaskBoardWorkflowKind::PrFixReview.is_write());
    }

    #[test]
    fn one_ticket_carries_both_intents_without_collapsing() {
        let both = TaskBoardWorkflowKind::PrFixReview;
        assert!(both.has_dependency_update_intent());
        assert!(both.has_review_request_intent());
        assert_eq!(
            both.pr_intents(),
            Some(PrIntentSet::DEPENDENCY_UPDATE.with(PrIntentSet::REVIEW_REQUEST))
        );
    }

    #[test]
    fn single_intent_kinds_carry_exactly_one() {
        assert!(TaskBoardWorkflowKind::PrFix.has_dependency_update_intent());
        assert!(!TaskBoardWorkflowKind::PrFix.has_review_request_intent());
        assert!(TaskBoardWorkflowKind::PrReview.has_review_request_intent());
        assert!(!TaskBoardWorkflowKind::PrReview.has_dependency_update_intent());
        assert_eq!(TaskBoardWorkflowKind::DefaultTask.pr_intents(), None);
    }

    #[test]
    fn union_backfills_and_merges_intents() {
        // An unclassified ticket adopts the discovered pull request kind.
        assert_eq!(
            TaskBoardWorkflowKind::DefaultTask.union(TaskBoardWorkflowKind::PrFix),
            TaskBoardWorkflowKind::PrFix
        );
        assert_eq!(
            TaskBoardWorkflowKind::Unknown.union(TaskBoardWorkflowKind::PrReview),
            TaskBoardWorkflowKind::PrReview
        );
        // Two pull request kinds union their intents.
        assert_eq!(
            TaskBoardWorkflowKind::PrReview.union(TaskBoardWorkflowKind::PrFix),
            TaskBoardWorkflowKind::PrFixReview
        );
        // A non-pull-request other never downgrades a pull request kind, and a
        // terminal Review keeps its own kind.
        assert_eq!(
            TaskBoardWorkflowKind::PrFix.union(TaskBoardWorkflowKind::DefaultTask),
            TaskBoardWorkflowKind::PrFix
        );
        assert_eq!(
            TaskBoardWorkflowKind::Review.union(TaskBoardWorkflowKind::PrFix),
            TaskBoardWorkflowKind::Review
        );
    }

    #[test]
    fn both_intents_route_as_write_never_read_only() {
        // PrFixReview carries a review intent but is a write workflow, so
        // read-only dispatch, launch, head-freezing, and publication/evaluation
        // gates must treat it as write. Only a pure PrReview is read-only.
        assert!(TaskBoardWorkflowKind::PrFixReview.is_write());
        assert!(TaskBoardWorkflowKind::PrFixReview.has_review_request_intent());
        assert!(!TaskBoardWorkflowKind::PrFixReview.is_read_only_review());
        assert!(TaskBoardWorkflowKind::PrReview.is_read_only_review());
        assert!(!TaskBoardWorkflowKind::PrReview.is_write());
        assert!(!TaskBoardWorkflowKind::Review.is_read_only_review());
    }

    #[test]
    fn imported_admission_mode_follows_intent() {
        // A review runs read-only; a dependency update - alone or combined -
        // writes headless; a combined ticket keeps its write mode without
        // shedding its review intent.
        assert_eq!(
            TaskBoardWorkflowKind::PrReview.imported_admission_agent_mode(),
            Some(AgentMode::Evaluate)
        );
        assert_eq!(
            TaskBoardWorkflowKind::PrFix.imported_admission_agent_mode(),
            Some(AgentMode::Headless)
        );
        assert_eq!(
            TaskBoardWorkflowKind::PrFixReview.imported_admission_agent_mode(),
            Some(AgentMode::Headless)
        );
        assert!(TaskBoardWorkflowKind::PrFixReview.has_review_request_intent());
        // Non-pull-request kinds keep whatever mode the item already carries.
        for kind in [
            TaskBoardWorkflowKind::Unknown,
            TaskBoardWorkflowKind::DefaultTask,
            TaskBoardWorkflowKind::Review,
        ] {
            assert_eq!(kind.imported_admission_agent_mode(), None);
        }
    }

    #[test]
    fn wire_values_stay_backward_compatible() {
        for (kind, wire) in [
            (TaskBoardWorkflowKind::Unknown, "unknown"),
            (TaskBoardWorkflowKind::DefaultTask, "default_task"),
            (TaskBoardWorkflowKind::Review, "review"),
            (TaskBoardWorkflowKind::PrFix, "pr_fix"),
            (TaskBoardWorkflowKind::PrReview, "pr_review"),
            (TaskBoardWorkflowKind::PrFixReview, "pr_fix_review"),
        ] {
            assert_eq!(kind.as_wire_str(), wire);
            assert_eq!(
                serde_json::to_string(&kind).expect("serialize"),
                format!("\"{wire}\"")
            );
            assert_eq!(
                serde_json::from_str::<TaskBoardWorkflowKind>(&format!("\"{wire}\""))
                    .expect("deserialize"),
                kind
            );
        }
    }

    #[test]
    fn default_is_default_task() {
        assert_eq!(
            TaskBoardWorkflowKind::default(),
            TaskBoardWorkflowKind::DefaultTask
        );
    }
}
