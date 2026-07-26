use std::fs;

use super::*;
use crate::run::workflow::{PreflightState, PreflightStatus};
use crate::run::{RunCounts, Verdict};

fn sample_status(run_id: &str, suite_id: &str) -> RunStatus {
    RunStatus {
        run_id: run_id.to_string(),
        suite_id: suite_id.to_string(),
        profile: "single-zone".to_string(),
        started_at: String::new(),
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    }
}

#[test]
fn resolve_phase_context_keeps_group_only_for_execution() {
    let state = RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: String::new(),
        transition_count: 0,
        last_event: None,
        history: Vec::new(),
    };
    let mut status = sample_status("r1", "s1");
    status.next_planned_group = Some("g03".to_string());

    let context = resolve_phase_context(Some(&state), Some(&status), None, None);
    assert_eq!(context.phase, "execution");
    assert_eq!(context.group_id.as_deref(), Some("g03"));

    let context = resolve_phase_context(Some(&state), Some(&status), Some("closeout"), None);
    assert_eq!(context.phase, "closeout");
    assert!(context.group_id.is_none());
}

#[test]
fn append_runner_state_audit_records_runner_state_write() {
    let tempdir = tempfile::tempdir().unwrap();
    let run_dir = tempdir.path().join("r01");
    let layout = RunLayout::from_run_dir(&run_dir);
    layout.ensure_dirs().unwrap();

    let mut status = sample_status("r01", "suite");
    status.last_completed_group = Some("g02".to_string());
    status.next_planned_group = Some("g03".to_string());
    status.save(&layout.status_path()).unwrap();

    let state = RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: String::new(),
        transition_count: 0,
        last_event: None,
        history: Vec::new(),
    };

    append_runner_state_audit(&run_dir, &state).unwrap();

    let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
    assert!(log_contents.contains("\"tool_name\":\"RunnerStateWrite\""));
    assert!(log_contents.contains("\"group_id\":\"g03\""));
}
