use std::path::{Path, PathBuf};

use clap::{Args, Subcommand};
use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
use crate::session::service::TaskSpec;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::dispatch::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchPlan, DispatchReadiness, SessionIntent,
};
use crate::task_board::external::ExternalSyncConfig;
use crate::task_board::store::{
    OptionalFieldPatch, TaskBoardItemPatch, TaskBoardStore, default_board_root,
};
use crate::task_board::summary::{
    build_audit_summary, build_dispatch_summary, build_machine_summaries, build_project_summaries,
    build_sync_summary,
};
use crate::task_board::types::{
    AgentMode, PlanningState, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TaskBoardWorkflowStatus,
};
use crate::workspace::utc_now;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardCommand {
    /// Create a board task.
    Create(TaskBoardCreateArgs),
    /// List board tasks.
    List(TaskBoardListArgs),
    /// Show one board task.
    Get(TaskBoardGetArgs),
    /// Update one board task.
    Update(TaskBoardUpdateArgs),
    /// Tombstone one board task.
    Delete(TaskBoardDeleteArgs),
    /// Run external synchronization.
    Sync(TaskBoardSyncArgs),
    /// Dispatch ready work into sessions.
    Dispatch(TaskBoardDispatchArgs),
    /// Print task-board audit data.
    Audit(TaskBoardAuditArgs),
    /// Manage known projects.
    Project(TaskBoardCatalogArgs),
    /// Manage known worker machines.
    Machine(TaskBoardCatalogArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardCreateArgs {
    #[arg(long)]
    pub title: String,
    #[arg(long, default_value = "")]
    pub body: String,
    #[arg(long, value_enum, default_value = "medium")]
    pub priority: TaskBoardPriority,
    #[arg(long, value_enum, default_value = "headless")]
    pub agent_mode: AgentMode,
    #[arg(long)]
    pub tag: Vec<String>,
    #[arg(long)]
    pub project_id: Option<String>,
    #[arg(long)]
    pub id: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardListArgs {
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardGetArgs {
    pub id: String,
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardUpdateArgs {
    pub id: String,
    #[arg(long)]
    pub title: Option<String>,
    #[arg(long)]
    pub body: Option<String>,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long, value_enum)]
    pub priority: Option<TaskBoardPriority>,
    #[arg(long, value_enum)]
    pub agent_mode: Option<AgentMode>,
    #[arg(long)]
    pub tag: Vec<String>,
    #[arg(long)]
    pub project_id: Option<String>,
    #[arg(long)]
    pub clear_project: bool,
    #[arg(long)]
    pub planning_summary: Option<String>,
    #[arg(long)]
    pub approved_by: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDeleteArgs {
    pub id: String,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardSyncArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardCatalogArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDispatchArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub actor: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardAuditArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

impl Execute for TaskBoardCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Create(args) => args.execute(context),
            Self::List(args) => args.execute(context),
            Self::Get(args) => args.execute(context),
            Self::Update(args) => args.execute(context),
            Self::Delete(args) => args.execute(context),
            Self::Sync(args) => args.execute(context),
            Self::Dispatch(args) => args.execute(context),
            Self::Audit(args) => args.execute(context),
            Self::Project(args) => args.execute_project(context),
            Self::Machine(args) => args.execute_machine(context),
        }
    }
}

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
        let patch = self.patch();
        let item = store(self.board_root.clone()).update(&self.id, patch)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl TaskBoardUpdateArgs {
    fn patch(&self) -> TaskBoardItemPatch {
        let planning = self.planning_patch();
        TaskBoardItemPatch {
            title: self.title.clone(),
            body: self.body.clone(),
            status: self.status,
            priority: self.priority,
            tags: (!self.tag.is_empty()).then(|| self.tag.clone()),
            project_id: self.project_patch(),
            agent_mode: self.agent_mode,
            planning,
            ..TaskBoardItemPatch::default()
        }
    }

    fn project_patch(&self) -> OptionalFieldPatch<String> {
        if self.clear_project {
            return OptionalFieldPatch::Clear;
        }
        self.project_id
            .clone()
            .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
    }

    fn planning_patch(&self) -> Option<PlanningState> {
        if self.planning_summary.is_none() && self.approved_by.is_none() {
            return None;
        }
        Some(PlanningState {
            summary: self.planning_summary.clone(),
            approved_by: self.approved_by.clone(),
            approved_at: self.approved_by.as_ref().map(|_| utc_now()),
        })
    }
}

impl Execute for TaskBoardDeleteArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = store(self.board_root.clone()).delete(&self.id)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardSyncArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(None)?;
        let payload = build_sync_summary(&items, &ExternalSyncConfig::from_env());
        if self.json {
            print_json(&payload)?;
        } else {
            println!("task-board sync: {} local items", payload.total);
            for provider in payload.providers {
                println!(
                    "{:?}: configured={}, linked={}, pushable={}, blocked={}",
                    provider.provider,
                    provider.configured,
                    provider.linked,
                    provider.pushable,
                    provider.blocked
                );
            }
        }
        Ok(0)
    }
}

impl TaskBoardCatalogArgs {
    fn execute_project(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(None)?;
        let summaries = build_project_summaries(&items);
        if self.json {
            print_json(&summaries)?;
        } else {
            for summary in summaries {
                println!(
                    "{}: {} items, {} ready",
                    summary.project_id, summary.item_count, summary.ready_count
                );
            }
        }
        Ok(0)
    }

    fn execute_machine(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(None)?;
        let summaries = build_machine_summaries(&items);
        if self.json {
            print_json(&summaries)?;
        } else {
            for summary in summaries {
                println!(
                    "{:?}: {} items, {} ready",
                    summary.mode, summary.item_count, summary.ready_count
                );
            }
        }
        Ok(0)
    }
}

impl Execute for TaskBoardDispatchArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let board = store(self.board_root.clone());
        let items = board.list(None)?;
        let plans = build_dispatch_summary(&items);
        let summary = if self.dry_run {
            DispatchExecutionSummary::dry_run(plans)
        } else {
            let mut applied = Vec::new();
            for plan in plans.iter().filter(|plan| plan.is_ready()) {
                applied.push(self.apply_plan(&board, plan)?);
            }
            DispatchExecutionSummary { plans, applied }
        };
        if self.json {
            print_json(&summary)?;
        } else {
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
        Ok(0)
    }
}

impl TaskBoardDispatchArgs {
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
        let current = board.get(&plan.board_item_id)?;
        let mut workflow = current.workflow;
        if workflow.execution_id.is_none() {
            workflow.execution_id = Some(new_workflow_execution_id());
        }
        workflow.status = TaskBoardWorkflowStatus::Running;
        workflow.current_step_id = Some("dispatch".to_string());
        workflow.attempts = workflow.attempts.saturating_add(1);
        workflow.policy_trace_ids.push(new_policy_trace_id());
        let item = board.update(
            &plan.board_item_id,
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::InProgress),
                workflow: Some(workflow),
                session_id: OptionalFieldPatch::Set(session_id.clone()),
                work_item_id: OptionalFieldPatch::Set(task.task_id.clone()),
                ..TaskBoardItemPatch::default()
            },
        )?;
        Ok(DispatchAppliedTask {
            board_item_id: plan.board_item_id.clone(),
            session_id,
            work_item_id: task.task_id,
            item,
        })
    }

    fn session_id_for_plan(&self, plan: &DispatchPlan) -> Result<String, CliError> {
        match &plan.session {
            SessionIntent::Existing { session_id } => Ok(session_id.clone()),
            SessionIntent::Create {
                title,
                context,
                project_id: _,
            } => {
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
                std::env::current_dir()
                    .map_err(|error| CliErrorKind::workflow_io(error.to_string()).into())
            },
            |path| Ok(Path::new(path).to_path_buf()),
        )
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

fn store(root: Option<PathBuf>) -> TaskBoardStore {
    TaskBoardStore::new(root.unwrap_or_else(default_board_root))
}

fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}

fn new_workflow_execution_id() -> String {
    format!("workflow-{}", Uuid::new_v4().simple())
}

fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", Uuid::new_v4().simple())
}

fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

fn dispatch_readiness_label(readiness: &DispatchReadiness) -> &'static str {
    match readiness {
        DispatchReadiness::Ready => "ready",
        DispatchReadiness::Blocked { .. } => "blocked",
    }
}
