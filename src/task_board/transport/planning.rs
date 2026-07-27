use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::task_board::wire::{
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
};
use harness_kernel::errors::CliError;

use super::{leaf_daemon_client, leaf_daemon_client_error, print_json};

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanBeginArgs {
    pub id: String,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanSubmitArgs {
    pub id: String,
    #[arg(long)]
    pub summary: String,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanApproveArgs {
    pub id: String,
    #[arg(long)]
    pub approved_by: String,
    #[arg(long)]
    pub approved_at: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardPlanRevokeArgs {
    pub id: String,
    #[arg(long)]
    pub actor: Option<String>,
}

impl Execute for TaskBoardPlanBeginArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardPlanBeginRequest {
            id: self.id.clone(),
        };
        let response: TaskBoardPlanningResponse = leaf_daemon_client()?
            .post(&planning_action_path(&self.id, "begin"), &request)
            .map_err(|error| leaf_daemon_client_error("begin task-board planning", &error))?;
        print_json(&response)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPlanSubmitArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardPlanSubmitRequest {
            id: self.id.clone(),
            summary: self.summary.clone(),
        };
        let response: TaskBoardPlanningResponse = leaf_daemon_client()?
            .post(&planning_action_path(&self.id, "submit"), &request)
            .map_err(|error| leaf_daemon_client_error("submit task-board plan", &error))?;
        print_json(&response)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPlanApproveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardPlanApproveRequest {
            id: self.id.clone(),
            approved_by: self.approved_by.clone(),
            approved_at: self.approved_at.clone(),
        };
        let response: TaskBoardPlanningResponse = leaf_daemon_client()?
            .post(&planning_action_path(&self.id, "approve"), &request)
            .map_err(|error| leaf_daemon_client_error("approve task-board plan", &error))?;
        print_json(&response)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPlanRevokeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardPlanRevokeRequest {
            id: self.id.clone(),
            actor: self.actor.clone(),
        };
        let response: TaskBoardPlanningResponse = leaf_daemon_client()?
            .post(&planning_action_path(&self.id, "revoke"), &request)
            .map_err(|error| leaf_daemon_client_error("revoke task-board plan", &error))?;
        print_json(&response)?;
        Ok(0)
    }
}

fn planning_action_path(item_id: &str, action: &str) -> String {
    format!("/v1/task-board/items/{item_id}/planning/{action}")
}
