use clap::Args;

use crate::infra::io;
use crate::task_board::wire::{
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest, TaskBoardPlanRevokeRequest,
    TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
};
use harness_kernel::errors::CliError;
use harness_workspace::command_context::{AppContext, Execute};

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
        io::validate_safe_segment(&self.id)?;
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
        io::validate_safe_segment(&self.id)?;
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
        io::validate_safe_segment(&self.id)?;
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
        io::validate_safe_segment(&self.id)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A daemon route path is one URL segment per `{item_id}` placeholder; an
    /// id smuggling a path separator or `..` would target a different route
    /// than the one asked for, since neither `planning_action_path` nor the
    /// leaf client URL-encodes it.
    #[test]
    fn begin_rejects_an_id_that_would_escape_its_path_segment() {
        let error = TaskBoardPlanBeginArgs {
            id: "../orchestrator/stop".to_string(),
        }
        .execute(&AppContext)
        .expect_err("an id with a path separator must be rejected before any request is sent");
        assert!(error.to_string().contains("../orchestrator/stop"));
    }

    #[test]
    fn submit_rejects_an_id_that_would_escape_its_path_segment() {
        let error = TaskBoardPlanSubmitArgs {
            id: "foo/../bar".to_string(),
            summary: "summary".to_string(),
        }
        .execute(&AppContext)
        .expect_err("an id with a path separator must be rejected before any request is sent");
        assert!(error.to_string().contains("foo/../bar"));
    }

    #[test]
    fn approve_rejects_an_id_that_would_escape_its_path_segment() {
        let error = TaskBoardPlanApproveArgs {
            id: "../orchestrator/stop".to_string(),
            approved_by: "reviewer".to_string(),
            approved_at: None,
        }
        .execute(&AppContext)
        .expect_err("an id with a path separator must be rejected before any request is sent");
        assert!(error.to_string().contains("../orchestrator/stop"));
    }

    #[test]
    fn revoke_rejects_an_id_that_would_escape_its_path_segment() {
        let error = TaskBoardPlanRevokeArgs {
            id: "foo/../bar".to_string(),
            actor: None,
        }
        .execute(&AppContext)
        .expect_err("an id with a path separator must be rejected before any request is sent");
        assert!(error.to_string().contains("foo/../bar"));
    }
}
