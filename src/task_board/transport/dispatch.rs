use std::env;
use std::path::{Path, PathBuf};

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
use crate::session::service::TaskSpec;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::dispatch::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchPlan, DispatchReadiness, SessionIntent,
};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::summary::build_dispatch_summary_with_policy_root;
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus};

use super::{
    TaskBoardDispatchArgs, new_policy_trace_id, new_workflow_execution_id, print_json, store,
};

impl Execute for TaskBoardDispatchArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let board = store(self.board_root.clone());
        let items = self.selected_items(&board)?;
        let plans = build_dispatch_summary_with_policy_root(&items, board.root());
        let summary = if self.dry_run {
            DispatchExecutionSummary::dry_run(plans)
        } else {
            self.apply_plans(&board, plans)?
        };
        if self.json {
            print_json(&summary)?;
        } else {
            print_dispatch_summary(&summary);
        }
        Ok(0)
    }
}

impl TaskBoardDispatchArgs {
    fn selected_items(&self, board: &TaskBoardStore) -> Result<Vec<TaskBoardItem>, CliError> {
        self.item_id.as_deref().map_or_else(
            || board.list(self.status),
            |item_id| board.get(item_id).map(|item| vec![item]),
        )
    }

    fn apply_plans(
        &self,
        board: &TaskBoardStore,
        plans: Vec<DispatchPlan>,
    ) -> Result<DispatchExecutionSummary, CliError> {
        let mut applied = Vec::new();
        for plan in plans.iter().filter(|plan| plan.is_ready()) {
            applied.push(self.apply_plan(board, plan)?);
        }
        Ok(DispatchExecutionSummary { plans, applied })
    }

    fn apply_plan(
        &self,
        board: &TaskBoardStore,
        plan: &DispatchPlan,
    ) -> Result<DispatchAppliedTask, CliError> {
        let actor = self.actor.as_deref().unwrap_or(CONTROL_PLANE_ACTOR_ID);
        let session_id = self.session_id_for_plan(plan)?;
        let project = self.project_dir_for_session(&session_id)?;
        let task = session_service::create_task_with_source(
            &session_id,
            &TaskSpec {
                title: &plan.task.title,
                context: plan.task.context.as_deref(),
                severity: plan.task.severity,
                suggested_fix: plan.task.suggested_fix.as_deref(),
                source: plan.task.source,
                observe_issue_id: None,
            },
            actor,
            &project,
        )?;
        let item = Self::link_item(board, plan, &session_id, &task.task_id)?;
        Ok(DispatchAppliedTask {
            board_item_id: plan.board_item_id.clone(),
            session_id,
            work_item_id: task.task_id,
            lifecycle: plan.applied_lifecycle(),
            item,
        })
    }

    fn link_item(
        board: &TaskBoardStore,
        plan: &DispatchPlan,
        session_id: &str,
        work_item_id: &str,
    ) -> Result<TaskBoardItem, CliError> {
        let current = board.get(&plan.board_item_id)?;
        let mut workflow = current.workflow;
        if workflow.execution_id.is_none() {
            workflow.execution_id = Some(new_workflow_execution_id());
        }
        workflow.status = TaskBoardWorkflowStatus::Running;
        workflow.current_step_id = Some("dispatch".to_string());
        workflow.attempts = workflow.attempts.saturating_add(1);
        workflow.push_policy_trace_id(new_policy_trace_id());
        board.update(
            &plan.board_item_id,
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::InProgress),
                workflow: Some(workflow),
                session_id: OptionalFieldPatch::Set(session_id.to_string()),
                work_item_id: OptionalFieldPatch::Set(work_item_id.to_string()),
                ..TaskBoardItemPatch::default()
            },
        )
    }

    fn session_id_for_plan(&self, plan: &DispatchPlan) -> Result<String, CliError> {
        match &plan.session {
            SessionIntent::Existing { session_id } => Ok(session_id.clone()),
            SessionIntent::Create { title, context, .. } => {
                let project = self.dispatch_project_dir()?;
                let state = session_service::start_session_with_policy(
                    context.as_deref().unwrap_or(title),
                    title,
                    &project,
                    None,
                    None,
                )?;
                Ok(state.session_id)
            }
        }
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<PathBuf, CliError> {
        let local_project = self.dispatch_project_dir()?;
        session_service::resolve_session_project_dir(session_id, &local_project)
    }

    fn dispatch_project_dir(&self) -> Result<PathBuf, CliError> {
        self.project_dir.as_deref().map_or_else(
            || {
                env::current_dir()
                    .map_err(|error| CliErrorKind::workflow_io(error.to_string()).into())
            },
            |path| Ok(Path::new(path).to_path_buf()),
        )
    }
}

fn print_dispatch_summary(summary: &DispatchExecutionSummary) {
    for plan in &summary.plans {
        println!(
            "[{}] {}",
            dispatch_readiness_label(&plan.readiness),
            plan.board_item_id
        );
    }
    if !summary.applied.is_empty() {
        println!("applied {} task-board dispatches", summary.applied.len());
    }
}

fn dispatch_readiness_label(readiness: &DispatchReadiness) -> &'static str {
    match readiness {
        DispatchReadiness::Ready => "ready",
        DispatchReadiness::Blocked { .. } => "blocked",
    }
}
