use serde::{Deserialize, Serialize};

use super::types::{PlanningState, TaskBoardItem, TaskBoardStatus};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanningTransition {
    pub board_item_id: String,
    pub from_status: TaskBoardStatus,
    pub to_status: TaskBoardStatus,
    pub planning: PlanningState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum PlanApprovalGate {
    Approved {
        approved_by: String,
        approved_at: String,
    },
    Blocked {
        reason: PlanApprovalBlockReason,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanApprovalBlockReason {
    Deleted,
    MissingSummary,
    MissingApprover,
    MissingApprovalTime,
}

impl PlanningTransition {
    #[must_use]
    pub fn apply_to(&self, item: &TaskBoardItem) -> TaskBoardItem {
        let mut updated = item.clone();
        updated.status = self.to_status;
        updated.planning = self.planning.clone();
        updated
    }
}

#[must_use]
pub fn begin_planning(item: &TaskBoardItem) -> PlanningTransition {
    transition(
        item,
        TaskBoardStatus::Planning,
        clear_approval(&item.planning),
    )
}

#[must_use]
pub fn submit_plan(item: &TaskBoardItem, summary: &str) -> PlanningTransition {
    let planning = PlanningState {
        summary: non_empty(summary),
        approved_by: None,
        approved_at: None,
    };
    transition(item, TaskBoardStatus::PlanReview, planning)
}

#[must_use]
pub fn approve_plan(
    item: &TaskBoardItem,
    approved_by: &str,
    approved_at: &str,
) -> PlanningTransition {
    let planning = PlanningState {
        summary: item.planning.summary.clone(),
        approved_by: non_empty(approved_by),
        approved_at: non_empty(approved_at),
    };
    transition(item, TaskBoardStatus::Todo, planning)
}

#[must_use]
pub fn approval_gate(item: &TaskBoardItem) -> PlanApprovalGate {
    if item.is_deleted() {
        return blocked(PlanApprovalBlockReason::Deleted);
    }
    if item.planning.summary.as_deref().is_none_or(str::is_empty) {
        return blocked(PlanApprovalBlockReason::MissingSummary);
    }
    let Some(approved_by) = item.planning.approved_by.as_deref() else {
        return blocked(PlanApprovalBlockReason::MissingApprover);
    };
    let Some(approved_at) = item.planning.approved_at.as_deref() else {
        return blocked(PlanApprovalBlockReason::MissingApprovalTime);
    };
    PlanApprovalGate::Approved {
        approved_by: approved_by.to_string(),
        approved_at: approved_at.to_string(),
    }
}

fn transition(
    item: &TaskBoardItem,
    to_status: TaskBoardStatus,
    planning: PlanningState,
) -> PlanningTransition {
    PlanningTransition {
        board_item_id: item.id.clone(),
        from_status: item.status,
        to_status,
        planning,
    }
}

fn clear_approval(planning: &PlanningState) -> PlanningState {
    PlanningState {
        summary: planning.summary.clone(),
        approved_by: None,
        approved_at: None,
    }
}

fn blocked(reason: PlanApprovalBlockReason) -> PlanApprovalGate {
    PlanApprovalGate::Blocked { reason }
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item() -> TaskBoardItem {
        TaskBoardItem::new(
            "task-1".into(),
            "Ship planning".into(),
            "body".into(),
            "2026-05-14T00:00:00Z".into(),
        )
    }

    #[test]
    fn submit_plan_moves_to_plan_review_and_clears_approval() {
        let mut item = item();
        item.planning.approved_by = Some("lead".into());
        item.planning.approved_at = Some("2026-05-14T01:00:00Z".into());

        let transition = submit_plan(&item, " Implement the board flow. ");
        let updated = transition.apply_to(&item);

        assert_eq!(updated.status, TaskBoardStatus::PlanReview);
        assert_eq!(
            updated.planning.summary.as_deref(),
            Some("Implement the board flow.")
        );
        assert_eq!(updated.planning.approved_by, None);
        assert_eq!(updated.planning.approved_at, None);
    }

    #[test]
    fn approve_plan_moves_to_todo_and_records_approval() {
        let item = item();
        let item = submit_plan(&item, "plan").apply_to(&item);

        let transition = approve_plan(&item, " lead ", " 2026-05-14T02:00:00Z ");
        let updated = transition.apply_to(&item);

        assert_eq!(updated.status, TaskBoardStatus::Todo);
        assert_eq!(updated.planning.summary.as_deref(), Some("plan"));
        assert_eq!(updated.planning.approved_by.as_deref(), Some("lead"));
        assert_eq!(
            updated.planning.approved_at.as_deref(),
            Some("2026-05-14T02:00:00Z")
        );
    }

    #[test]
    fn approval_gate_blocks_missing_approval() {
        let item = item();
        let item = submit_plan(&item, "plan").apply_to(&item);

        assert_eq!(
            approval_gate(&item),
            PlanApprovalGate::Blocked {
                reason: PlanApprovalBlockReason::MissingApprover
            }
        );
    }
}
