use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest,
};
use crate::errors::CliError;

use super::{daemon_client, print_json};

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
        let response = daemon_client()?.begin_task_board_planning(&TaskBoardPlanBeginRequest {
            id: self.id.clone(),
        })?;
        print_json(&response)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPlanSubmitArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.submit_task_board_plan(&TaskBoardPlanSubmitRequest {
            id: self.id.clone(),
            summary: self.summary.clone(),
        })?;
        print_json(&response)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPlanApproveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.approve_task_board_plan(&TaskBoardPlanApproveRequest {
            id: self.id.clone(),
            approved_by: self.approved_by.clone(),
            approved_at: self.approved_at.clone(),
        })?;
        print_json(&response)?;
        Ok(0)
    }
}

impl Execute for TaskBoardPlanRevokeArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.revoke_task_board_plan(&TaskBoardPlanRevokeRequest {
            id: self.id.clone(),
            actor: self.actor.clone(),
        })?;
        print_json(&response)?;
        Ok(0)
    }
}
