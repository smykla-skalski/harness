use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
};

use uuid::Uuid;

use crate::errors::CliError;
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::utc_now;

use super::dispatch::DispatchExecutionSummary;
use super::evaluation::TaskBoardEvaluationSummary;
use super::external::ExternalSyncConfig;
use super::store::TaskBoardStore;
use super::summary::{
    TaskBoardAuditSummary, TaskBoardSyncSummary, build_audit_summary, build_sync_summary,
};
use super::types::{TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus};

mod settings;
mod types;

use self::settings::{apply_settings_update, dispatch_input, normalize_github_inbox};
pub use self::types::*;

const SETTINGS_FILE: &str = "orchestrator-settings.json";
const STATE_FILE: &str = "orchestrator-state.json";

#[derive(Debug, Clone)]
pub struct TaskBoardOrchestrator {
    board: TaskBoardStore,
    root: PathBuf,
}

impl TaskBoardOrchestrator {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self {
            board: TaskBoardStore::new(root.clone()),
            root,
        }
    }

    /// Load durable orchestrator settings, returning defaults when absent.
    ///
    /// # Errors
    /// Returns `CliError` when the settings JSON exists but cannot be read.
    pub fn settings(&self) -> Result<TaskBoardOrchestratorSettings, CliError> {
        read_or_default(&self.settings_path())
    }

    /// Persist a partial settings update and return the merged settings.
    ///
    /// # Errors
    /// Returns `CliError` when settings cannot be read or written.
    pub fn update_settings(
        &self,
        update: &TaskBoardOrchestratorSettingsUpdateRequest,
    ) -> Result<TaskBoardOrchestratorSettings, CliError> {
        let mut settings = self.settings()?;
        apply_settings_update(&mut settings, update);
        settings.github_inbox = normalize_github_inbox(&settings.github_inbox)?;
        write_json_pretty(&self.settings_path(), &settings)?;
        Ok(settings)
    }

    /// Load the current durable orchestrator status.
    ///
    /// # Errors
    /// Returns `CliError` when state, settings, or board items cannot be read.
    pub fn status(&self) -> Result<TaskBoardOrchestratorStatus, CliError> {
        self.status_from_state(self.state()?)
    }

    /// Persist start intent and return status.
    ///
    /// # Errors
    /// Returns `CliError` when state cannot be read or written.
    pub fn start(&self) -> Result<TaskBoardOrchestratorStatus, CliError> {
        self.set_running_intent(true, true)
    }

    /// Persist stop intent and return status.
    ///
    /// # Errors
    /// Returns `CliError` when state cannot be read or written.
    pub fn stop(&self) -> Result<TaskBoardOrchestratorStatus, CliError> {
        self.set_running_intent(false, false)
    }

    /// Execute one orchestrator tick using the supplied dispatch executor.
    ///
    /// # Errors
    /// Returns `CliError` when board data, durable state, or dispatch fails.
    pub fn run_once<F>(
        &self,
        request: &TaskBoardOrchestratorRunOnceRequest,
        dispatch: F,
    ) -> Result<TaskBoardOrchestratorStatus, CliError>
    where
        F: FnOnce(
            &TaskBoardOrchestratorDispatchInput,
        ) -> Result<DispatchExecutionSummary, CliError>,
    {
        let prepared = self.prepare_run(request)?;
        match dispatch(&prepared.input) {
            Ok(dispatch) => self.complete_run(prepared, dispatch),
            Err(error) => {
                self.fail_run(&prepared, &error)?;
                Err(error)
            }
        }
    }

    /// Execute one autonomous tick only when durable state is enabled/running.
    ///
    /// # Errors
    /// Returns `CliError` when status loading or the delegated tick fails.
    pub fn run_autonomous_once<F>(
        &self,
        dispatch: F,
    ) -> Result<TaskBoardOrchestratorStatus, CliError>
    where
        F: FnOnce(
            &TaskBoardOrchestratorDispatchInput,
        ) -> Result<DispatchExecutionSummary, CliError>,
    {
        let state = self.state()?;
        if !state.enabled || !state.running {
            return self.status_from_state(state);
        }
        self.run_once(&TaskBoardOrchestratorRunOnceRequest::default(), dispatch)
    }

    /// Prepare one tick and persist current tick metadata before dispatch.
    ///
    /// # Errors
    /// Returns `CliError` when settings, board items, or state cannot be read.
    pub fn prepare_run(
        &self,
        request: &TaskBoardOrchestratorRunOnceRequest,
    ) -> Result<TaskBoardOrchestratorPreparedRun, CliError> {
        let settings = self.settings()?;
        let input = dispatch_input(request, &settings);
        let run_id = new_run_id();
        let started_at = utc_now();
        self.record_tick(
            &run_id,
            &started_at,
            input.dry_run,
            TaskBoardOrchestratorTickPhase::Dispatch,
        )?;
        let items = run_items(&self.board, input.item_id.as_deref(), input.status)?;
        Ok(TaskBoardOrchestratorPreparedRun {
            run_id,
            started_at,
            input,
            sync: build_sync_summary(&items, &ExternalSyncConfig::from_env()),
            audit: build_audit_summary(&items),
        })
    }

    /// Load the board items selected by one prepared dispatch input.
    ///
    /// # Errors
    /// Returns `CliError` when selected board items cannot be read.
    pub(crate) fn items_for_input(
        &self,
        input: &TaskBoardOrchestratorDispatchInput,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        run_items(&self.board, input.item_id.as_deref(), input.status)
    }

    /// Persist a phase transition for an in-flight prepared tick.
    ///
    /// # Errors
    /// Returns `CliError` when durable state cannot be written.
    pub fn record_run_phase(
        &self,
        prepared: &TaskBoardOrchestratorPreparedRun,
        phase: TaskBoardOrchestratorTickPhase,
    ) -> Result<(), CliError> {
        self.record_tick(
            &prepared.run_id,
            &prepared.started_at,
            prepared.input.dry_run,
            phase,
        )
    }

    /// Complete a prepared tick and persist the run summary.
    ///
    /// # Errors
    /// Returns `CliError` when durable state cannot be written.
    pub fn complete_run(
        &self,
        prepared: TaskBoardOrchestratorPreparedRun,
        dispatch: DispatchExecutionSummary,
    ) -> Result<TaskBoardOrchestratorStatus, CliError> {
        self.complete_run_with_evaluation(prepared, dispatch, None)
    }

    /// Complete a prepared tick and persist dispatch plus evaluation results.
    ///
    /// # Errors
    /// Returns `CliError` when durable state cannot be written.
    pub fn complete_run_with_evaluation(
        &self,
        prepared: TaskBoardOrchestratorPreparedRun,
        dispatch: DispatchExecutionSummary,
        evaluation: Option<TaskBoardEvaluationSummary>,
    ) -> Result<TaskBoardOrchestratorStatus, CliError> {
        self.finish_run(run_record(RunRecordInput {
            run_id: prepared.run_id,
            started_at: prepared.started_at,
            dry_run: prepared.input.dry_run,
            sync: prepared.sync,
            audit: prepared.audit,
            dispatch: Some(dispatch),
            evaluation,
            error: None,
        }))
    }

    /// Persist a failed prepared tick.
    ///
    /// # Errors
    /// Returns `CliError` when durable state cannot be written.
    pub fn fail_run(
        &self,
        prepared: &TaskBoardOrchestratorPreparedRun,
        error: &CliError,
    ) -> Result<(), CliError> {
        let summary = run_record(RunRecordInput {
            run_id: prepared.run_id.clone(),
            started_at: prepared.started_at.clone(),
            dry_run: prepared.input.dry_run,
            sync: prepared.sync.clone(),
            audit: prepared.audit.clone(),
            dispatch: None,
            evaluation: None,
            error: Some(error.to_string()),
        });
        self.save_last_run(summary, TaskBoardOrchestratorTickPhase::Failed)
    }

    fn status_from_state(
        &self,
        state: TaskBoardOrchestratorState,
    ) -> Result<TaskBoardOrchestratorStatus, CliError> {
        Ok(TaskBoardOrchestratorStatus {
            enabled: state.enabled,
            running: state.running,
            current_tick: state.current_tick,
            last_run: state.last_run,
            workflow_execution_counts: self.workflow_execution_counts()?,
            settings: self.settings()?,
        })
    }

    fn set_running_intent(
        &self,
        enabled: bool,
        running: bool,
    ) -> Result<TaskBoardOrchestratorStatus, CliError> {
        let mut state = self.state()?;
        state.enabled = enabled;
        state.running = running;
        self.save_state(&state)?;
        self.status_from_state(state)
    }

    fn record_tick(
        &self,
        run_id: &str,
        started_at: &str,
        dry_run: bool,
        phase: TaskBoardOrchestratorTickPhase,
    ) -> Result<(), CliError> {
        let mut state = self.state()?;
        state.current_tick = Some(TaskBoardOrchestratorTickInfo {
            run_id: run_id.to_string(),
            phase,
            started_at: started_at.to_string(),
            completed_at: None,
            dry_run,
        });
        self.save_state(&state)
    }

    fn finish_run(
        &self,
        summary: TaskBoardOrchestratorRunSummary,
    ) -> Result<TaskBoardOrchestratorStatus, CliError> {
        self.save_last_run(summary, TaskBoardOrchestratorTickPhase::Completed)?;
        self.status()
    }

    fn save_last_run(
        &self,
        summary: TaskBoardOrchestratorRunSummary,
        phase: TaskBoardOrchestratorTickPhase,
    ) -> Result<(), CliError> {
        let mut state = self.state()?;
        state.current_tick = Some(TaskBoardOrchestratorTickInfo {
            run_id: summary.run_id.clone(),
            phase,
            started_at: summary.started_at.clone(),
            completed_at: Some(summary.completed_at.clone()),
            dry_run: summary.dry_run,
        });
        state.last_run = Some(summary);
        self.save_state(&state)
    }

    fn workflow_execution_counts(&self) -> Result<Vec<TaskBoardWorkflowExecutionCount>, CliError> {
        let items = self.board.list(None)?;
        Ok(workflow_statuses()
            .into_iter()
            .filter_map(|status| {
                let count = items
                    .iter()
                    .filter(|item| item.workflow.status == status)
                    .count();
                (count > 0).then_some(TaskBoardWorkflowExecutionCount { status, count })
            })
            .collect())
    }

    fn state(&self) -> Result<TaskBoardOrchestratorState, CliError> {
        read_or_default(&self.state_path())
    }

    fn save_state(&self, state: &TaskBoardOrchestratorState) -> Result<(), CliError> {
        write_json_pretty(&self.state_path(), state)
    }

    fn settings_path(&self) -> PathBuf {
        self.root.join(SETTINGS_FILE)
    }

    fn state_path(&self) -> PathBuf {
        self.root.join(STATE_FILE)
    }
}

fn run_items(
    board: &TaskBoardStore,
    item_id: Option<&str>,
    status: Option<TaskBoardStatus>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    item_id.map_or_else(
        || board.list(status),
        |id| board.get(id).map(|item| vec![item]),
    )
}

struct RunRecordInput {
    run_id: String,
    started_at: String,
    dry_run: bool,
    sync: TaskBoardSyncSummary,
    audit: TaskBoardAuditSummary,
    dispatch: Option<DispatchExecutionSummary>,
    evaluation: Option<TaskBoardEvaluationSummary>,
    error: Option<String>,
}

fn run_record(input: RunRecordInput) -> TaskBoardOrchestratorRunSummary {
    let policy_trace_ids = policy_trace_ids(input.dispatch.as_ref(), input.evaluation.as_ref());
    TaskBoardOrchestratorRunSummary {
        run_id: input.run_id,
        started_at: input.started_at,
        completed_at: utc_now(),
        status: if input.error.is_some() {
            TaskBoardOrchestratorRunStatus::Failed
        } else {
            TaskBoardOrchestratorRunStatus::Completed
        },
        dry_run: input.dry_run,
        sync: input.sync,
        audit: input.audit,
        dispatch: input.dispatch,
        evaluation: input.evaluation,
        error: input.error,
        policy_trace_ids,
    }
}

fn policy_trace_ids(
    dispatch: Option<&DispatchExecutionSummary>,
    evaluation: Option<&TaskBoardEvaluationSummary>,
) -> Vec<String> {
    let mut trace_ids = BTreeSet::new();
    if let Some(dispatch) = dispatch {
        for applied in &dispatch.applied {
            trace_ids.extend(applied.item.workflow.policy_trace_ids.iter().cloned());
        }
    }
    if let Some(evaluation) = evaluation {
        for record in &evaluation.records {
            if let Some(item) = &record.item {
                trace_ids.extend(item.workflow.policy_trace_ids.iter().cloned());
            }
        }
    }
    trace_ids.into_iter().collect()
}

const fn workflow_statuses() -> [TaskBoardWorkflowStatus; 6] {
    [
        TaskBoardWorkflowStatus::Idle,
        TaskBoardWorkflowStatus::Running,
        TaskBoardWorkflowStatus::Paused,
        TaskBoardWorkflowStatus::Completed,
        TaskBoardWorkflowStatus::Failed,
        TaskBoardWorkflowStatus::Cancelled,
    ]
}

fn read_or_default<T>(path: &Path) -> Result<T, CliError>
where
    T: Default + for<'de> serde::Deserialize<'de>,
{
    if path.exists() {
        read_json_typed(path)
    } else {
        Ok(T::default())
    }
}

fn new_run_id() -> String {
    format!("task-board-run-{}", Uuid::new_v4().simple())
}

#[cfg(test)]
mod tests;
