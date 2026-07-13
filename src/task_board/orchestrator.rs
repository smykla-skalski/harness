#[cfg(test)]
use std::path::PathBuf;

#[cfg(test)]
use crate::errors::CliError;
#[cfg(test)]
use crate::infra::io::write_json_pretty;
#[cfg(test)]
use crate::workspace::utc_now;

#[cfg(test)]
use super::dispatch::DispatchExecutionSummary;
#[cfg(test)]
use super::evaluation::TaskBoardEvaluationSummary;
#[cfg(test)]
use super::external::ExternalSyncConfig;
#[cfg(test)]
use super::machines::{Machine, MachineRegistry};
#[cfg(test)]
use super::store::TaskBoardStore;
#[cfg(test)]
use super::summary::{build_audit_summary, build_sync_summary};
#[cfg(test)]
use super::types::TaskBoardItem;

#[cfg(test)]
mod run_record;
mod settings;
mod types;

#[cfg(test)]
use self::run_record::{
    RunRecordInput, new_run_id, read_or_default, run_items_for_machine, run_record,
    workflow_statuses,
};
pub(crate) use self::settings::parse_persisted_settings_read_only;
#[cfg(test)]
use self::settings::{
    apply_settings_update, dispatch_input, migrate_persisted_settings, normalize_github_inbox,
    normalize_todoist_inbox,
};
pub use self::types::*;

#[cfg(test)]
const SETTINGS_FILE: &str = "orchestrator-settings.json";
#[cfg(test)]
const STATE_FILE: &str = "orchestrator-state.json";

#[derive(Debug, Clone)]
#[cfg(test)]
pub struct TaskBoardOrchestrator {
    board: TaskBoardStore,
    root: PathBuf,
}

#[cfg(test)]
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
        let path = self.settings_path();
        Ok(migrate_persisted_settings(&path)?.unwrap_or_default())
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
        settings.todoist_inbox = normalize_todoist_inbox(&settings.todoist_inbox);
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

    /// Return a minimal status built from `state.json` only, without reading
    /// settings or board items. Callers that need only `enabled`/`running`
    /// (e.g. the autonomous loop guard) can use this to avoid the full parse.
    ///
    /// # Errors
    /// Returns `CliError` when `state.json` cannot be read.
    pub fn state_as_status(&self) -> Result<TaskBoardOrchestratorStatus, CliError> {
        let state = self.state()?;
        Ok(TaskBoardOrchestratorStatus {
            enabled: state.enabled,
            running: state.running,
            step_mode: false,
            current_tick: None,
            last_run: None,
            workflow_execution_counts: Vec::new(),
            settings: TaskBoardOrchestratorSettings::default(),
        })
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
        let machine = self.local_machine().ok();
        let items = run_items_for_machine(
            &self.board,
            input.item_id.as_deref(),
            input.status,
            machine.as_ref(),
        )?;
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
    #[cfg(test)]
    pub(crate) fn items_for_input(
        &self,
        input: &TaskBoardOrchestratorDispatchInput,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let machine = self.local_machine().ok();
        run_items_for_machine(
            &self.board,
            input.item_id.as_deref(),
            input.status,
            machine.as_ref(),
        )
    }

    /// Return the persisted local machine record, creating one if missing.
    ///
    /// # Errors
    /// Returns `CliError` when the registry directory or records cannot be read.
    pub fn local_machine(&self) -> Result<Machine, CliError> {
        MachineRegistry::new(self.root.clone()).ensure_local()
    }

    #[must_use]
    pub fn machine_registry(&self) -> MachineRegistry {
        MachineRegistry::new(self.root.clone())
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
        let settings = self.settings()?;
        Ok(TaskBoardOrchestratorStatus {
            enabled: state.enabled,
            running: state.running,
            step_mode: settings.step_mode,
            current_tick: state.current_tick,
            last_run: state.last_run,
            workflow_execution_counts: self.workflow_execution_counts()?,
            settings,
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
        let machine = self.local_machine().ok();
        let items = run_items_for_machine(&self.board, None, None, machine.as_ref())?;
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

#[cfg(test)]
mod tests;
