use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    TaskBoardAuditRequest, TaskBoardCreateItemRequest, TaskBoardListItemsRequest,
    TaskBoardUpdateIdentityClears, TaskBoardUpdateItemRequest, TaskBoardUpdateStateClears,
};
use crate::errors::CliError;
use crate::task_board::TaskBoardWorkflowKind;
use crate::task_board::types::{ExternalRef, TaskBoardItem};

use super::{
    TaskBoardAuditArgs, TaskBoardCreateArgs, TaskBoardDeleteArgs, TaskBoardGetArgs,
    TaskBoardListArgs, TaskBoardUpdateArgs, daemon_client, print_json,
};

impl Execute for TaskBoardCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardCreateItemRequest {
            title: self.title.clone(),
            body: self.body.clone(),
            priority: self.priority,
            agent_mode: self.agent_mode,
            workflow_kind: TaskBoardWorkflowKind::default(),
            execution_repository: None,
            tags: self.tag.clone(),
            project_id: self.project_id.clone(),
            target_project_types: self.target_project_type.clone(),
            external_refs: self.fields.external_refs(),
            planning: self.fields.planning().unwrap_or_default(),
            workflow: self.fields.workflow(None),
            session_id: self.fields.session_id.clone(),
            work_item_id: self.fields.work_item_id.clone(),
            id: self.id.clone(),
        };
        let item = daemon_client()?.create_task_board_item(&request)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = daemon_client()?.list_task_board_items(&TaskBoardListItemsRequest {
            status: self.status,
        })?;
        if self.json {
            print_json(&items)?;
        } else {
            for item in items {
                println!(
                    "[{:?}] {} - {} ({:?})",
                    item.priority, item.id, item.title, item.status
                );
            }
        }
        Ok(0)
    }
}

impl Execute for TaskBoardGetArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = daemon_client()?.get_task_board_item(&self.id)?;
        if self.json {
            print_json(&item)?;
        } else {
            println!("{} - {}\n\n{}", item.id, item.title, item.body);
        }
        Ok(0)
    }
}

impl Execute for TaskBoardUpdateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let client = daemon_client()?;
        let current = self
            .fields
            .has_workflow_update()
            .then(|| client.get_task_board_item(&self.id))
            .transpose()?;
        let request = self.request(current.as_ref());
        let item = client.update_task_board_item(&self.id, &request)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl TaskBoardUpdateArgs {
    fn request(&self, current: Option<&TaskBoardItem>) -> TaskBoardUpdateItemRequest {
        TaskBoardUpdateItemRequest {
            title: self.title.clone(),
            body: self.body.clone(),
            status: self.status,
            priority: self.priority,
            agent_mode: self.agent_mode,
            workflow_kind: None,
            execution_repository: None,
            tags: (!self.tag.is_empty()).then(|| self.tag.clone()),
            project_id: self.project_id.clone(),
            target_project_types: (!self.target_project_type.is_empty())
                .then(|| self.target_project_type.clone()),
            clear_identity: TaskBoardUpdateIdentityClears {
                clear_project_id: self.clear_links.clear_project,
                clear_execution_repository: false,
                clear_session_id: self.clear_links.clear_session,
                clear_work_item_id: self.clear_links.clear_work_item,
            },
            external_refs: self.external_refs_patch(),
            planning: self.fields.planning(),
            clear_state: TaskBoardUpdateStateClears {
                clear_planning: self.clear_state.clear_planning,
                clear_workflow: self.clear_state.clear_workflow,
            },
            workflow: self.fields.workflow(current.map(|item| &item.workflow)),
            session_id: self.fields.session_id.clone(),
            work_item_id: self.fields.work_item_id.clone(),
        }
    }

    fn external_refs_patch(&self) -> Option<Vec<ExternalRef>> {
        if self.clear_state.clear_external_refs {
            Some(Vec::new())
        } else {
            self.fields
                .has_external_refs()
                .then(|| self.fields.external_refs())
        }
    }
}

impl Execute for TaskBoardDeleteArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = daemon_client()?.delete_task_board_item(&self.id)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardAuditArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let summary = daemon_client()?.audit_task_board(&TaskBoardAuditRequest { status: None })?;
        if self.json {
            print_json(&summary)?;
        } else {
            println!(
                "task-board: {} total, {} ready, {} blocked",
                summary.total, summary.ready, summary.blocked
            );
        }
        Ok(0)
    }
}
