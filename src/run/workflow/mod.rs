mod persistence;
mod transitions;
mod types;

use std::fmt;
use std::path::Path;

use crate::run::audit::append_runner_state_audit;
use crate::errors::{CliError, CliErrorKind};

pub use persistence::{
    initialize_runner_state, read_runner_state, runner_state_path, write_runner_state,
    write_runner_state_if_current,
};
pub use types::{
    FailureKind, FailureState, ManifestFixDecision, PreflightState, PreflightStatus, RunnerEvent,
    RunnerNextAction, RunnerPhase, RunnerWorkflowState, SuiteFixState, TransitionRecord,
};

use persistence::{make_initial_state, runner_repository};
use transitions::{
    apply_failure_manifest, apply_preflight_status, apply_suite_fix,
    clear_triage_state_on_forward_movement, resolve_transition,
};

fn now_utc() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// Apply a named event to the runner state, advancing the phase when valid.
///
/// Returns the updated state after persisting to disk. Invalid transitions
/// produce `CliErrorKind::InvalidTransition`.
///
/// # Errors
/// Returns `CliError` on invalid transition or IO failure.
pub fn apply_event<E>(
    run_dir: &Path,
    event: E,
    suite_target: Option<&str>,
    message: Option<&str>,
) -> Result<RunnerWorkflowState, CliError>
where
    E: TryInto<RunnerEvent>,
    E::Error: fmt::Display,
{
    let event = event
        .try_into()
        .map_err(|error| CliErrorKind::invalid_transition(format!("unknown event: {error}")))?;
    let _ = read_runner_state(run_dir)?;
    let repo = runner_repository(run_dir);
    let updated = repo.update(|current| {
        let mut state = current.unwrap_or_else(|| make_initial_state(&now_utc()));

        let new_phase = resolve_transition(&mut state, event)?;
        state.phase = new_phase;

        clear_triage_state_on_forward_movement(&mut state, new_phase);
        apply_preflight_status(&mut state, event);
        apply_failure_manifest(&mut state, event, suite_target, message);
        apply_suite_fix(&mut state, event, new_phase, suite_target);

        Ok(Some(state))
    })?;
    let Some(state) = updated else {
        unreachable!("runner updates always persist a state");
    };
    append_runner_state_audit(run_dir, &state)?;
    Ok(state)
}

/// Advance the runner phase to the execution phase if it is still in
/// bootstrap or preflight. Called automatically when commands like
/// `report group` or `apply` indicate the run is actively executing.
///
/// Returns `true` if the phase was advanced, `false` if already past those
/// early phases.
///
/// # Errors
/// Returns `CliError` on IO failure.
pub fn ensure_execution_phase(run_dir: &Path) -> Result<bool, CliError> {
    let _ = read_runner_state(run_dir)?;
    let repo = runner_repository(run_dir);
    let updated = repo.update(|current| {
        let Some(mut state) = current else {
            return Ok(None);
        };
        if matches!(state.phase, RunnerPhase::Bootstrap | RunnerPhase::Preflight) {
            state.phase = RunnerPhase::Execution;
            state.touch("AutoAdvanceToExecution");
            return Ok(Some(state));
        }
        Ok(None)
    })?;
    if let Some(state) = updated.as_ref() {
        append_runner_state_audit(run_dir, state)?;
    }
    Ok(updated.is_some())
}

/// Get the next action hint based on runner state.
#[must_use]
pub fn next_action(state: Option<&RunnerWorkflowState>) -> RunnerNextAction {
    let Some(state) = state else {
        return RunnerNextAction::ReloadState;
    };
    match state.phase {
        RunnerPhase::Bootstrap => RunnerNextAction::FinishBootstrap,
        RunnerPhase::Preflight => {
            if state.preflight.status == PreflightStatus::Running {
                RunnerNextAction::FinishPreflightWorker
            } else {
                RunnerNextAction::ExecutePreflight
            }
        }
        RunnerPhase::Execution => RunnerNextAction::ContinueExecution,
        RunnerPhase::Triage => {
            if state.suite_fix.is_some() {
                RunnerNextAction::FinishSuiteRepair
            } else {
                RunnerNextAction::ResolveTriage
            }
        }
        RunnerPhase::Closeout => RunnerNextAction::FinishCloseout,
        RunnerPhase::Completed => RunnerNextAction::ReviewReport,
        RunnerPhase::Suspended => RunnerNextAction::ResumeRun,
        RunnerPhase::Aborted => RunnerNextAction::HandleAbort,
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths, clippy::cognitive_complexity)]

    use super::*;
    use tempfile::TempDir;

    use persistence::make_initial_state;
    use transitions::{event_label, is_valid_transition};

    fn bootstrap_state() -> RunnerWorkflowState {
        make_initial_state("2025-01-01T00:00:00Z")
    }

    fn setup_execution_phase() -> TempDir {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        apply_event(dir.path(), "preflight-captured", None, None).unwrap();
        dir
    }

    #[test]
    fn runner_phase_display() {
        let cases = [
            (RunnerPhase::Bootstrap, "bootstrap"),
            (RunnerPhase::Preflight, "preflight"),
            (RunnerPhase::Execution, "execution"),
            (RunnerPhase::Triage, "triage"),
            (RunnerPhase::Closeout, "closeout"),
            (RunnerPhase::Completed, "completed"),
            (RunnerPhase::Aborted, "aborted"),
            (RunnerPhase::Suspended, "suspended"),
        ];
        for (variant, expected) in cases {
            assert_eq!(variant.to_string(), expected);
        }
    }

    #[test]
    fn runner_phase_serialization_round_trip() {
        let state = bootstrap_state();
        let json = serde_json::to_value(&state).unwrap();
        assert_eq!(json["state"]["phase"], "bootstrap");
        assert_eq!(json["state"]["preflight"]["status"], "pending");
        let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
    }

    #[test]
    fn failure_kind_serialization() {
        let f = FailureState {
            kind: FailureKind::Manifest,
            suite_target: Some("groups/g1".to_string()),
            message: None,
        };
        let json = serde_json::to_value(&f).unwrap();
        assert_eq!(json["kind"], "manifest");
        assert_eq!(json["suite_target"], "groups/g1");
        assert!(json.get("message").is_none());
    }

    #[test]
    fn manifest_fix_decision_serialization() {
        let json = serde_json::to_value(ManifestFixDecision::SuiteAndRun).unwrap();
        assert_eq!(json, "Fix in suite and this run");
        let loaded: ManifestFixDecision = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, ManifestFixDecision::SuiteAndRun);
    }

    #[test]
    fn suite_fix_ready_to_resume_both_true() {
        let fix = SuiteFixState {
            approved_paths: vec!["a".to_string()],
            suite_written: true,
            amendments_written: true,
            decision: ManifestFixDecision::SuiteAndRun,
        };
        assert!(fix.ready_to_resume());
    }

    #[test]
    fn suite_fix_not_ready_when_partial() {
        let fix = SuiteFixState {
            approved_paths: vec![],
            suite_written: true,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        };
        assert!(!fix.ready_to_resume());
    }

    #[test]
    fn initialize_and_read_round_trip() {
        let dir = TempDir::new().unwrap();
        let state = initialize_runner_state(dir.path()).unwrap();
        assert_eq!(state.phase, RunnerPhase::Bootstrap);
        assert_eq!(state.transition_count, 0);
        let loaded = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Bootstrap);
    }

    #[test]
    fn write_and_read_runner_state() {
        let dir = TempDir::new().unwrap();
        let mut state = bootstrap_state();
        state.phase = RunnerPhase::Execution;
        state.transition_count = 3;
        write_runner_state(dir.path(), &state).unwrap();
        let loaded = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(loaded.phase, RunnerPhase::Execution);
        assert_eq!(loaded.transition_count, 3);
    }

    #[test]
    fn read_returns_none_when_missing() {
        let dir = TempDir::new().unwrap();
        assert!(read_runner_state(dir.path()).unwrap().is_none());
    }

    #[test]
    fn next_action_none_state() {
        assert_eq!(next_action(None), RunnerNextAction::ReloadState);
        assert!(next_action(None).to_string().contains("Reload"));
    }

    #[test]
    fn next_action_each_phase() {
        let mut state = bootstrap_state();
        assert_eq!(next_action(Some(&state)), RunnerNextAction::FinishBootstrap);
        assert!(next_action(Some(&state)).to_string().contains("bootstrap"));

        state.phase = RunnerPhase::Preflight;
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::ExecutePreflight
        );
        assert!(next_action(Some(&state)).to_string().contains("preflight"));

        state.preflight.status = PreflightStatus::Running;
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::FinishPreflightWorker
        );
        assert!(
            next_action(Some(&state))
                .to_string()
                .contains("preflight worker")
        );

        state.phase = RunnerPhase::Execution;
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::ContinueExecution
        );
        assert!(next_action(Some(&state)).to_string().contains("execution"));

        state.phase = RunnerPhase::Triage;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::ResolveTriage);
        assert!(next_action(Some(&state)).to_string().contains("triage"));

        state.phase = RunnerPhase::Closeout;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::FinishCloseout);
        assert!(next_action(Some(&state)).to_string().contains("closeout"));

        state.phase = RunnerPhase::Completed;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::ReviewReport);
        assert!(
            next_action(Some(&state))
                .to_string()
                .contains("final verdict")
        );

        state.phase = RunnerPhase::Aborted;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::HandleAbort);
        assert!(next_action(Some(&state)).to_string().contains("guard-stop"));

        state.phase = RunnerPhase::Suspended;
        assert_eq!(next_action(Some(&state)), RunnerNextAction::ResumeRun);
        assert!(next_action(Some(&state)).to_string().contains("suspended"));
    }

    #[test]
    fn next_action_triage_with_suite_fix() {
        let mut state = bootstrap_state();
        state.phase = RunnerPhase::Triage;
        state.suite_fix = Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: false,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        });
        assert_eq!(
            next_action(Some(&state)),
            RunnerNextAction::FinishSuiteRepair
        );
        assert!(
            next_action(Some(&state))
                .to_string()
                .contains("suite repair")
        );
    }

    #[test]
    fn runner_state_path_builds_correctly() {
        let path = runner_state_path(std::path::Path::new("/runs/r1"));
        assert_eq!(
            path,
            std::path::PathBuf::from("/runs/r1/suite-run-state.json")
        );
    }

    #[test]
    fn full_state_serialization_with_all_fields() {
        let state = RunnerWorkflowState {
            schema_version: 1,
            phase: RunnerPhase::Triage,
            preflight: PreflightState {
                status: PreflightStatus::Complete,
            },
            failure: Some(FailureState {
                kind: FailureKind::Manifest,
                suite_target: Some("groups/g1".to_string()),
                message: Some("test failed".to_string()),
            }),
            suite_fix: Some(SuiteFixState {
                approved_paths: vec!["groups/g1".to_string()],
                suite_written: true,
                amendments_written: false,
                decision: ManifestFixDecision::SuiteAndRun,
            }),
            updated_at: "2025-01-01T00:00:00Z".to_string(),
            transition_count: 5,
            last_event: Some("ManifestFixAnswered".to_string()),
            history: Vec::new(),
        };
        let json = serde_json::to_value(&state).unwrap();
        let loaded: RunnerWorkflowState = serde_json::from_value(json).unwrap();
        assert_eq!(loaded, state);
    }

    #[test]
    fn preflight_status_variants_serialize() {
        for (variant, expected) in [
            (PreflightStatus::Pending, "pending"),
            (PreflightStatus::Running, "running"),
            (PreflightStatus::Complete, "complete"),
        ] {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn failure_kind_variants_serialize() {
        for (variant, expected) in [
            (FailureKind::Manifest, "manifest"),
            (FailureKind::Environment, "environment"),
            (FailureKind::Product, "product"),
        ] {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn manifest_fix_decision_all_variants() {
        let cases = [
            (ManifestFixDecision::RunOnly, "Fix for this run only"),
            (
                ManifestFixDecision::SuiteAndRun,
                "Fix in suite and this run",
            ),
            (ManifestFixDecision::SkipStep, "Skip this step"),
            (ManifestFixDecision::StopRun, "Stop run"),
        ];
        for (variant, expected) in cases {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(json, expected);
        }
    }

    // --- apply_event tests ---

    #[test]
    fn apply_event_cluster_prepared_advances_to_preflight() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Preflight);
        assert_eq!(state.transition_count, 1);
        assert_eq!(state.last_event.as_deref(), Some("ClusterPrepared"));
    }

    #[test]
    fn apply_event_full_happy_path() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Preflight);

        let state = apply_event(dir.path(), "preflight-started", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Preflight);
        assert_eq!(state.preflight.status, PreflightStatus::Running);

        let state = apply_event(dir.path(), "preflight-captured", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
        assert_eq!(state.preflight.status, PreflightStatus::Complete);

        let state = apply_event(dir.path(), "closeout-started", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Closeout);

        let state = apply_event(dir.path(), "run-completed", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Completed);
        assert_eq!(state.transition_count, 5);
    }

    #[test]
    fn apply_event_abort_from_execution() {
        let dir = setup_execution_phase();
        let state = apply_event(dir.path(), "abort", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Aborted);
    }

    #[test]
    fn apply_event_suspend_and_resume() {
        let dir = setup_execution_phase();

        let state = apply_event(dir.path(), "suspend", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Suspended);

        let state = apply_event(dir.path(), "resume-run", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn apply_event_resume_from_aborted() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "abort", None, None).unwrap();

        let state = apply_event(dir.path(), "resume-run", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn apply_event_invalid_transition_rejected() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        // Cannot go to closeout from bootstrap.
        let result = apply_event(dir.path(), "closeout-started", None, None);
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert_eq!(error.code(), "KSRCLI084");
    }

    #[test]
    fn apply_event_unknown_event_rejected() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let result = apply_event(dir.path(), "made-up-event", None, None);
        assert!(result.is_err());
        assert!(result.unwrap_err().message().contains("unknown event"));
    }

    #[test]
    fn apply_event_failure_manifest_sets_triage() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let state = apply_event(
            dir.path(),
            "failure-manifest",
            Some("groups/g1.md"),
            Some("parse error"),
        )
        .unwrap();
        assert_eq!(state.phase, RunnerPhase::Triage);
        assert!(state.failure.is_some());
        let failure = state.failure.unwrap();
        assert_eq!(failure.kind, FailureKind::Manifest);
        assert_eq!(failure.suite_target.as_deref(), Some("groups/g1.md"));
        assert_eq!(failure.message.as_deref(), Some("parse error"));
    }

    #[test]
    fn apply_event_manifest_fix_suite_and_run_sets_suite_fix() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "failure-manifest", Some("groups/g1.md"), None).unwrap();

        let state = apply_event(
            dir.path(),
            "manifest-fix-suite-and-run",
            Some("groups/g1.md"),
            None,
        )
        .unwrap();
        assert_eq!(state.phase, RunnerPhase::Triage);
        let fix = state.suite_fix.unwrap();
        assert_eq!(fix.decision, ManifestFixDecision::SuiteAndRun);
        assert_eq!(fix.approved_paths, vec!["groups/g1.md"]);
        assert!(!fix.suite_written);
        assert!(!fix.amendments_written);
    }

    #[test]
    fn apply_event_manifest_fix_stop_run_aborts() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "failure-manifest", None, None).unwrap();

        let state = apply_event(dir.path(), "manifest-fix-stop-run", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Aborted);
    }

    #[test]
    fn apply_event_suite_fix_resumed_returns_to_execution() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "failure-manifest", None, None).unwrap();
        apply_event(dir.path(), "manifest-fix-run-only", None, None).unwrap();

        let state = apply_event(dir.path(), "suite-fix-resumed", None, None).unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
        // suite_fix should be cleared when leaving triage.
        assert!(state.suite_fix.is_none());
    }

    #[test]
    fn apply_event_cannot_transition_from_completed() {
        let dir = setup_execution_phase();
        apply_event(dir.path(), "closeout-started", None, None).unwrap();
        apply_event(dir.path(), "run-completed", None, None).unwrap();

        // Even abort should be rejected from completed.
        let result = apply_event(dir.path(), "abort", None, None);
        assert!(result.is_err());
    }

    // --- ensure_execution_phase tests ---

    #[test]
    fn ensure_execution_phase_from_bootstrap() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();

        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(advanced);

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
        assert_eq!(state.last_event.as_deref(), Some("AutoAdvanceToExecution"));
    }

    #[test]
    fn ensure_execution_phase_from_preflight() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();

        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(advanced);

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn ensure_execution_phase_noop_when_already_executing() {
        let dir = setup_execution_phase();

        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(!advanced);

        let state = read_runner_state(dir.path()).unwrap().unwrap();
        assert_eq!(state.phase, RunnerPhase::Execution);
    }

    #[test]
    fn ensure_execution_phase_noop_when_no_state() {
        let dir = TempDir::new().unwrap();
        let advanced = ensure_execution_phase(dir.path()).unwrap();
        assert!(!advanced);
    }

    // --- event_label tests ---

    #[test]
    fn event_label_camel_cases_dashed_name() {
        assert_eq!(event_label("cluster-prepared"), "ClusterPrepared");
        assert_eq!(event_label("preflight-started"), "PreflightStarted");
        assert_eq!(event_label("abort"), "Abort");
        assert_eq!(
            event_label("manifest-fix-suite-and-run"),
            "ManifestFixSuiteAndRun"
        );
    }

    // --- is_valid_transition tests ---

    #[test]
    fn valid_transitions_from_bootstrap() {
        assert!(is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Preflight,
            "cluster-prepared"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Execution,
            "preflight-captured"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Aborted,
            "abort"
        ));
        assert!(!is_valid_transition(
            RunnerPhase::Bootstrap,
            RunnerPhase::Closeout,
            "closeout-started"
        ));
    }

    #[test]
    fn valid_transitions_from_execution() {
        assert!(is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Closeout,
            "closeout-started"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Triage,
            "failure-manifest"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Suspended,
            "suspend"
        ));
        assert!(!is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Preflight,
            "preflight-started"
        ));
    }

    #[test]
    fn resume_only_from_suspended_or_aborted() {
        assert!(is_valid_transition(
            RunnerPhase::Suspended,
            RunnerPhase::Execution,
            "resume-run"
        ));
        assert!(is_valid_transition(
            RunnerPhase::Aborted,
            RunnerPhase::Execution,
            "resume-run"
        ));
        assert!(!is_valid_transition(
            RunnerPhase::Execution,
            RunnerPhase::Execution,
            "resume-run"
        ));
    }

    // -- Snapshot tests --

    #[test]
    fn snapshot_initial_state() {
        let state = make_initial_state("2026-01-01T00:00:00Z");
        let json = serde_json::to_value(&state).expect("serialize state");
        insta::assert_snapshot!(serde_json::to_string_pretty(&json).unwrap());
    }

    fn redact_timestamps(json: &mut serde_json::Value) {
        json["updated_at"] = serde_json::json!("REDACTED");
        json["state"]["updated_at"] = serde_json::json!("REDACTED");
        if let Some(history) = json["state"]["history"].as_array_mut() {
            for entry in history {
                entry["timestamp"] = serde_json::json!("REDACTED");
            }
        }
    }

    #[test]
    fn snapshot_state_after_cluster_prepared() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        let state = apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        let mut json = serde_json::to_value(&state).expect("serialize state");
        redact_timestamps(&mut json);
        insta::assert_snapshot!(serde_json::to_string_pretty(&json).unwrap());
    }

    #[test]
    fn snapshot_state_after_full_happy_path() {
        let dir = TempDir::new().unwrap();
        initialize_runner_state(dir.path()).unwrap();
        apply_event(dir.path(), "cluster-prepared", None, None).unwrap();
        apply_event(dir.path(), "preflight-captured", None, None).unwrap();
        apply_event(dir.path(), "closeout-started", None, None).unwrap();
        let state = apply_event(dir.path(), "run-completed", None, None).unwrap();
        let mut json = serde_json::to_value(&state).expect("serialize state");
        redact_timestamps(&mut json);
        insta::assert_snapshot!(serde_json::to_string_pretty(&json).unwrap());
    }
}
