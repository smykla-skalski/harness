use std::path::PathBuf;

use clap::Args;
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::task_board::planning::{PlanningTransition, approve_plan, begin_planning, submit_plan};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::TaskBoardItem;
use crate::workspace::utc_now;

use super::{print_json, store};

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanBeginArgs {
    pub id: String,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanSubmitArgs {
    pub id: String,
    #[arg(long)]
    pub summary: String,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanApproveArgs {
    pub id: String,
    #[arg(long)]
    pub approved_by: String,
    #[arg(long)]
    pub approved_at: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Serialize)]
struct TaskBoardPlanningResponse {
    transition: PlanningTransition,
    item: TaskBoardItem,
}

impl Execute for TaskBoardPlanBeginArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        apply_transition(self.board_root.clone(), self.id.as_str(), begin_planning)
    }
}

impl Execute for TaskBoardPlanSubmitArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        apply_transition(self.board_root.clone(), self.id.as_str(), |item| {
            submit_plan(item, self.summary.as_str())
        })
    }
}

impl Execute for TaskBoardPlanApproveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let approved_at = self.approved_at.clone().unwrap_or_else(utc_now);
        apply_transition(self.board_root.clone(), self.id.as_str(), |item| {
            approve_plan(item, self.approved_by.as_str(), approved_at.as_str())
        })
    }
}

fn apply_transition(
    board_root: Option<PathBuf>,
    id: &str,
    transition_for: impl FnOnce(&TaskBoardItem) -> PlanningTransition,
) -> Result<i32, CliError> {
    let board = store(board_root);
    let current = board.get(id)?;
    let transition = transition_for(&current);
    let item = board.update(
        id,
        TaskBoardItemPatch {
            status: Some(transition.to_status),
            planning: Some(transition.planning.clone()),
            ..TaskBoardItemPatch::default()
        },
    )?;
    print_json(&TaskBoardPlanningResponse { transition, item })?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::store::TaskBoardStore;
    use crate::task_board::types::TaskBoardStatus;
    use tempfile::tempdir;

    fn seed_item(board: &TaskBoardStore) {
        let item = TaskBoardItem::new(
            "task-1".into(),
            "Plan work".into(),
            "body".into(),
            "2026-05-14T00:00:00Z".into(),
        );
        board
            .create("Plan work", "body", item)
            .expect("create task-board item");
    }

    #[test]
    fn submit_and_approve_transition_item_to_ready_work() {
        let temp = tempdir().expect("tempdir");
        let board_root = temp.path().join("board");
        let board = TaskBoardStore::new(board_root.clone());
        seed_item(&board);

        TaskBoardPlanSubmitArgs {
            id: "task-1".into(),
            summary: "Use the reviewed implementation plan.".into(),
            board_root: Some(board_root.clone()),
        }
        .execute(&AppContext)
        .expect("submit plan");
        TaskBoardPlanApproveArgs {
            id: "task-1".into(),
            approved_by: "lead".into(),
            approved_at: Some("2026-05-14T02:00:00Z".into()),
            board_root: Some(board_root.clone()),
        }
        .execute(&AppContext)
        .expect("approve plan");

        let item = board.get("task-1").expect("load item");
        assert_eq!(item.status, TaskBoardStatus::Todo);
        assert_eq!(
            item.planning.summary.as_deref(),
            Some("Use the reviewed implementation plan.")
        );
        assert_eq!(item.planning.approved_by.as_deref(), Some("lead"));
        assert_eq!(
            item.planning.approved_at.as_deref(),
            Some("2026-05-14T02:00:00Z")
        );
    }

    #[test]
    fn begin_transition_clears_prior_approval() {
        let temp = tempdir().expect("tempdir");
        let board_root = temp.path().join("board");
        let board = TaskBoardStore::new(board_root.clone());
        seed_item(&board);
        TaskBoardPlanSubmitArgs {
            id: "task-1".into(),
            summary: "Use the reviewed implementation plan.".into(),
            board_root: Some(board_root.clone()),
        }
        .execute(&AppContext)
        .expect("submit plan");
        TaskBoardPlanApproveArgs {
            id: "task-1".into(),
            approved_by: "lead".into(),
            approved_at: Some("2026-05-14T02:00:00Z".into()),
            board_root: Some(board_root.clone()),
        }
        .execute(&AppContext)
        .expect("approve plan");

        TaskBoardPlanBeginArgs {
            id: "task-1".into(),
            board_root: Some(board_root.clone()),
        }
        .execute(&AppContext)
        .expect("begin planning");

        let item = board.get("task-1").expect("load item");
        assert_eq!(item.status, TaskBoardStatus::Planning);
        assert_eq!(item.planning.approved_by, None);
        assert_eq!(item.planning.approved_at, None);
    }
}
