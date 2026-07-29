//! Pull request intent carried by a task-board ticket.
//!
//! Relocated to `harness_protocol::daemon::task_board::item_intent` (#1145):
//! both types are pure data with only self-contained inherent methods, and
//! `harness-protocol` needed them to define `TaskBoardPolicyScope`/
//! `TaskBoardAutomationCancelTarget`, which embed `TaskBoardWorkflowKind`
//! directly. Re-exported here unchanged so every existing caller keeps
//! resolving `crate::item_intent::{PrIntentSet, TaskBoardWorkflowKind}`.
pub use harness_protocol::daemon::task_board::item_intent::{PrIntentSet, TaskBoardWorkflowKind};

#[cfg(test)]
use crate::types::AgentMode;

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
