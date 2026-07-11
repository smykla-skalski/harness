use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::summary::build_audit_summary;
use crate::task_board::types::{ExternalRef, TaskBoardItem};
use crate::workspace::utc_now;

use super::{
    TaskBoardAuditArgs, TaskBoardCreateArgs, TaskBoardDeleteArgs, TaskBoardGetArgs,
    TaskBoardListArgs, TaskBoardUpdateArgs, new_task_id, print_json, store,
};

impl Execute for TaskBoardCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let now = utc_now();
        let mut item = TaskBoardItem::new(
            self.id.clone().unwrap_or_else(new_task_id),
            self.title.clone(),
            self.body.clone(),
            now,
        );
        item.priority = self.priority;
        item.agent_mode = self.agent_mode;
        item.tags.clone_from(&self.tag);
        item.project_id.clone_from(&self.project_id);
        item.target_project_types
            .clone_from(&self.target_project_type);
        item.external_refs = self.fields.external_refs();
        if let Some(planning) = self.fields.planning() {
            item.planning = planning;
        }
        if let Some(workflow) = self.fields.workflow(None) {
            item.workflow = workflow;
        }
        item.session_id.clone_from(&self.fields.session_id);
        item.work_item_id.clone_from(&self.fields.work_item_id);
        let item = store(self.board_root.clone()).create(&self.title, &self.body, item)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(self.status)?;
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
        let item = store(self.board_root.clone()).get(&self.id)?;
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
        let board = store(self.board_root.clone());
        let current = self
            .fields
            .has_workflow_update()
            .then(|| board.get(&self.id))
            .transpose()?;
        let patch = self.patch(current.as_ref());
        let item = board.update(&self.id, patch)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl TaskBoardUpdateArgs {
    fn patch(&self, current: Option<&TaskBoardItem>) -> TaskBoardItemPatch {
        TaskBoardItemPatch {
            title: self.title.clone(),
            body: self.body.clone(),
            status: self.status,
            priority: self.priority,
            tags: (!self.tag.is_empty()).then(|| self.tag.clone()),
            project_id: self.project_patch(),
            target_project_types: (!self.target_project_type.is_empty())
                .then(|| self.target_project_type.clone()),
            agent_mode: self.agent_mode,
            external_refs: self.external_refs_patch(),
            planning: self.fields.planning(),
            clear_planning: self.clear_state.clear_planning,
            clear_approval: false,
            workflow: self.fields.workflow(current.map(|item| &item.workflow)),
            clear_workflow: self.clear_state.clear_workflow,
            session_id: self.session_patch(),
            work_item_id: self.work_item_patch(),
        }
    }

    fn project_patch(&self) -> OptionalFieldPatch<String> {
        if self.clear_links.clear_project {
            return OptionalFieldPatch::Clear;
        }
        self.project_id
            .clone()
            .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
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

    fn session_patch(&self) -> OptionalFieldPatch<String> {
        if self.clear_links.clear_session {
            return OptionalFieldPatch::Clear;
        }
        self.fields
            .session_id
            .clone()
            .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
    }

    fn work_item_patch(&self) -> OptionalFieldPatch<String> {
        if self.clear_links.clear_work_item {
            return OptionalFieldPatch::Clear;
        }
        self.fields
            .work_item_id
            .clone()
            .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
    }
}

impl Execute for TaskBoardDeleteArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = store(self.board_root.clone()).delete(&self.id)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardAuditArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(None)?;
        let summary = build_audit_summary(&items);
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
