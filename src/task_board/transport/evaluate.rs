use std::env;
use std::path::{Path, PathBuf};

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::session::service as session_service;
use crate::task_board::evaluation::{
    TaskBoardEvaluationRecord, TaskBoardEvaluationSummary, evaluate_task_board_item,
    failed_workflow, missing_session_record, missing_task_record, record_from_decision,
    skipped_unlinked_record,
};
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::transport::{print_json, store};
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};

#[derive(Debug, Clone, Args)]
pub struct TaskBoardEvaluateArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long = "item-id", visible_alias = "id")]
    pub item_id: Option<String>,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

impl Execute for TaskBoardEvaluateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let board = store(self.board_root.clone());
        let items = self.selected_items(&board)?;
        let mut summary = TaskBoardEvaluationSummary::default();
        for item in &items {
            let Some((session_id, work_item_id)) = linked_task(item) else {
                summary.push(skipped_unlinked_record(item));
                continue;
            };
            let project = self.project_dir_for_session(session_id)?;
            let task = match session_service::list_tasks(session_id, None, &project) {
                Ok(tasks) => tasks
                    .into_iter()
                    .find(|task| task.task_id == work_item_id && !task.is_deleted()),
                Err(error) => {
                    summary.push(self.failure_record(
                        &board,
                        item,
                        missing_session_record(item, error.to_string()),
                        "missing_session",
                    )?);
                    continue;
                }
            };
            let Some(task) = task else {
                summary.push(self.failure_record(
                    &board,
                    item,
                    missing_task_record(
                        item,
                        format!("session task '{work_item_id}' was not found"),
                    ),
                    "missing_task",
                )?);
                continue;
            };
            let decision = evaluate_task_board_item(item, &task);
            let changed = item.status != decision.status || item.workflow != decision.workflow;
            if self.dry_run || !changed {
                summary.push(record_from_decision(item, &decision, false, None));
                continue;
            }
            let updated_item = board.update(
                &item.id,
                TaskBoardItemPatch {
                    status: Some(decision.status),
                    workflow: Some(decision.workflow.clone()),
                    ..TaskBoardItemPatch::default()
                },
            )?;
            summary.push(record_from_decision(
                item,
                &decision,
                true,
                Some(updated_item),
            ));
        }
        if self.json {
            print_json(&summary)?;
        } else {
            println!(
                "task-board evaluate: {} evaluated, {} updated, {} skipped",
                summary.evaluated, summary.updated, summary.skipped
            );
            for record in &summary.records {
                println!("[{:?}] {}", record.outcome, record.board_item_id);
            }
        }
        Ok(0)
    }
}

impl TaskBoardEvaluateArgs {
    fn selected_items(&self, board: &TaskBoardStore) -> Result<Vec<TaskBoardItem>, CliError> {
        self.item_id.as_deref().map_or_else(
            || board.list(self.status),
            |item_id| board.get(item_id).map(|item| vec![item]),
        )
    }

    fn failure_record(
        &self,
        board: &TaskBoardStore,
        item: &TaskBoardItem,
        mut record: TaskBoardEvaluationRecord,
        step: &str,
    ) -> Result<TaskBoardEvaluationRecord, CliError> {
        if self.dry_run {
            return Ok(record);
        }
        let reason = record.reason.clone().unwrap_or_else(|| step.to_string());
        let workflow = failed_workflow(item, step, reason);
        let changed = item.status != TaskBoardStatus::Blocked || item.workflow != workflow;
        if !changed {
            return Ok(record);
        }
        let updated_item = board.update(
            &item.id,
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::Blocked),
                workflow: Some(workflow),
                ..TaskBoardItemPatch::default()
            },
        )?;
        record.updated = true;
        record.item = Some(updated_item);
        Ok(record)
    }

    fn project_dir_for_session(&self, session_id: &str) -> Result<PathBuf, CliError> {
        let local_project = self.local_project_dir()?;
        session_service::resolve_session_project_dir(session_id, &local_project)
    }

    fn local_project_dir(&self) -> Result<PathBuf, CliError> {
        self.project_dir.as_deref().map_or_else(
            || {
                env::current_dir()
                    .map_err(|error| CliErrorKind::workflow_io(error.to_string()).into())
            },
            |path| Ok(Path::new(path).to_path_buf()),
        )
    }
}

fn linked_task(item: &TaskBoardItem) -> Option<(&str, &str)> {
    Some((item.session_id.as_deref()?, item.work_item_id.as_deref()?))
}

#[cfg(test)]
mod tests {
    use harness_testkit::with_isolated_harness_env;
    use tempfile::tempdir;

    use super::*;
    use crate::session::service::TaskSpec;
    use crate::session::types::{CONTROL_PLANE_ACTOR_ID, TaskSeverity, TaskSource};
    use crate::task_board::store::{OptionalFieldPatch, TaskBoardStore};
    use crate::task_board::types::TaskBoardWorkflowStatus;

    #[test]
    fn execute_honors_dry_run_and_status_filter() {
        let temp = tempdir().expect("tempdir");
        with_isolated_harness_env(temp.path(), || {
            let project = temp.path().join("project");
            std::fs::create_dir_all(&project).expect("project dir");
            let session_id = "00000000-0000-4002-8000-000000000101";
            session_service::start_session(
                "evaluate linked work",
                "Evaluate linked work",
                &project,
                Some(session_id),
            )
            .expect("start session");
            let task = session_service::create_task_with_source(
                session_id,
                &TaskSpec {
                    title: "linked work",
                    context: None,
                    severity: TaskSeverity::Medium,
                    suggested_fix: None,
                    source: TaskSource::Manual,
                    observe_issue_id: None,
                },
                CONTROL_PLANE_ACTOR_ID,
                &project,
            )
            .expect("create task");

            let board_root = temp.path().join("board");
            let board = TaskBoardStore::new(board_root.clone());
            create_linked_item(
                &board,
                "task-selected",
                TaskBoardStatus::Todo,
                session_id,
                &task.task_id,
            );
            create_linked_item(
                &board,
                "task-ignored",
                TaskBoardStatus::New,
                session_id,
                &task.task_id,
            );

            let dry_run = TaskBoardEvaluateArgs {
                json: true,
                dry_run: true,
                item_id: None,
                status: Some(TaskBoardStatus::Todo),
                project_dir: Some(project.to_string_lossy().to_string()),
                board_root: Some(board_root.clone()),
            };
            assert_eq!(dry_run.execute(&AppContext).expect("dry-run"), 0);
            assert_eq!(
                board
                    .get("task-selected")
                    .expect("selected after dry-run")
                    .status,
                TaskBoardStatus::Todo
            );

            let update = TaskBoardEvaluateArgs {
                dry_run: false,
                ..dry_run
            };
            assert_eq!(update.execute(&AppContext).expect("update"), 0);

            let selected = board.get("task-selected").expect("selected after update");
            assert_eq!(selected.status, TaskBoardStatus::InProgress);
            assert_eq!(selected.workflow.status, TaskBoardWorkflowStatus::Running);
            assert_eq!(
                board
                    .get("task-ignored")
                    .expect("ignored after update")
                    .status,
                TaskBoardStatus::New
            );
        });
    }

    fn create_linked_item(
        board: &TaskBoardStore,
        id: &str,
        status: TaskBoardStatus,
        session_id: &str,
        work_item_id: &str,
    ) {
        let item = TaskBoardItem::new(
            id.to_string(),
            id.to_string(),
            String::new(),
            "2026-05-14T00:00:00Z".to_string(),
        );
        board.create(id, "", item).expect("create board item");
        board
            .update(
                id,
                TaskBoardItemPatch {
                    status: Some(status),
                    session_id: OptionalFieldPatch::Set(session_id.to_string()),
                    work_item_id: OptionalFieldPatch::Set(work_item_id.to_string()),
                    ..TaskBoardItemPatch::default()
                },
            )
            .expect("link board item");
    }
}
