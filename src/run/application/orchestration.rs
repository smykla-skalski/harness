use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};
use crate::run::args::RunDirArgs;
use crate::run::commands::closeout::closeout_run;
use crate::run::commands::init::{default_run_id, init_run_internal};
use crate::run::resolve::resolve_run_directory;
use crate::run::workflow::{
    RunnerEvent, RunnerNextAction, RunnerPhase, apply_event, next_action, read_runner_state,
    runner_state_path,
};
use crate::workspace::utc_now;

use super::{RunApplication, check_report_compactness};

#[derive(Debug, Clone)]
pub struct StartRunRequest<'a> {
    pub suite: &'a str,
    pub run_id: Option<&'a str>,
    pub profile: &'a str,
    pub repo_root: Option<&'a str>,
    pub run_root: Option<&'a str>,
}

#[derive(Debug, Clone)]
pub struct StartRunResult {
    pub run_dir: PathBuf,
}

#[derive(Debug, Clone)]
pub struct FinishRunResult {
    pub report_path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ResumeRunResult {
    pub run_dir: PathBuf,
    pub phase: RunnerPhase,
    pub next_action: RunnerNextAction,
    pub resumed: bool,
}

impl RunApplication {
    /// Initialize and preflight a new run in one step.
    ///
    /// # Errors
    /// Returns `CliError` when init or preflight fails.
    pub fn start(request: &StartRunRequest<'_>) -> Result<StartRunResult, CliError> {
        let run_id = request.run_id.map_or_else(default_run_id, str::to_string);
        let layout = init_run_internal(
            request.suite,
            &run_id,
            request.profile,
            request.repo_root,
            request.run_root,
        )?;

        let checked_at = utc_now();
        let run = Self::from_run_dir(&layout.run_dir())?;
        run.validate_requirement_names()?;
        let _ = run.save_preflight_outputs(&checked_at)?;
        run.record_preflight_complete()?;

        Ok(StartRunResult {
            run_dir: layout.run_dir(),
        })
    }

    /// Finish the active run by closing it out and validating the report.
    ///
    /// # Errors
    /// Returns `CliError` when closeout or report validation fails.
    pub fn finish(&self) -> Result<FinishRunResult, CliError> {
        closeout_run(self)?;
        let report_path = self.layout().report_path();
        let report = report_path.to_string_lossy().into_owned();
        let _ = check_report_compactness(Some(&report))?;
        // Best-effort cleanup - the pointer is stale after a successful finish.
        // `clear_current_pointer` already treats not-found as success; any
        // remaining error is a rare filesystem issue not worth blocking on.
        let _ = Self::clear_current_pointer();
        Ok(FinishRunResult { report_path })
    }

    /// Reattach the selected run and resume it when the workflow is recoverable.
    ///
    /// # Errors
    /// Returns `CliError` when the run cannot be resolved, is already finalized,
    /// or has no runner workflow state.
    pub fn resume(args: &RunDirArgs, message: Option<&str>) -> Result<ResumeRunResult, CliError> {
        let run_dir = resolve_run_directory(
            args.run_dir.as_deref(),
            args.run_id.as_deref(),
            args.run_root.as_deref(),
        )?
        .run_dir;
        let run = Self::from_run_dir(&run_dir)?;
        run.save_as_current()?;

        let state_path = runner_state_path(&run_dir);
        let state = read_runner_state(&run_dir)?
            .ok_or_else(|| CliErrorKind::missing_file(state_path.display().to_string()))?;
        let phase = state.phase();

        if phase == RunnerPhase::Completed
            || (run
                .status()
                .is_some_and(|status| status.overall_verdict.is_finalized())
                && phase != RunnerPhase::Suspended
                && phase != RunnerPhase::Aborted)
        {
            return Err(CliErrorKind::usage_error(format!(
                "run {} already has a final verdict; start a new run id instead",
                run.metadata().run_id
            ))
            .into());
        }

        let (phase, resumed) = match phase {
            RunnerPhase::Suspended | RunnerPhase::Aborted => {
                let state = apply_event(
                    &run_dir,
                    RunnerEvent::ResumeRun,
                    None,
                    Some(message.unwrap_or("Resumed via harness run resume")),
                )?;
                (state.phase(), true)
            }
            _ => (phase, false),
        };

        let state = read_runner_state(&run_dir)?
            .ok_or_else(|| CliErrorKind::missing_file(state_path.display().to_string()))?;
        Ok(ResumeRunResult {
            run_dir,
            phase,
            next_action: next_action(Some(&state)),
            resumed,
        })
    }
}
