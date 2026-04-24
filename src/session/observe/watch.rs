use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::thread;
use std::time::Duration;

use tokio::time::sleep;

use crate::errors::CliError;
use crate::observe::types::Issue;
use crate::session::service::{self, TaskSpec};
use crate::session::types::{SessionState, SessionStatus, TaskSeverity, TaskSource};

use super::scan::{AgentLogTailState, scan_all_agents, scan_all_agents_incremental};
use super::support::{
    create_work_items_for_issues, emit_watch_issues, persist_observer_snapshot,
    task_severity_for_issue,
};

/// How many polling cycles between periodic sweeps.
/// With default 3s poll interval, sweep runs every ~5 minutes.
const SWEEP_CYCLE_COUNT: u64 = 100;

struct WatchCycleState {
    realtime_seen: HashSet<String>,
    total_issues: usize,
    cycle_count: u64,
    tail_states: HashMap<String, AgentLogTailState>,
    shared_cross_agent_editors: HashMap<String, HashSet<String>>,
}

/// Run the continuous multi-agent observation loop.
///
/// Two modes work together:
/// - **Real-time**: polls each agent's log at `poll_interval_seconds`,
///   running the classifier on new lines and creating work items.
/// - **Periodic sweep**: every `SWEEP_CYCLE_COUNT` polls, runs a full
///   re-scan. If the sweep catches issues the real-time watcher missed,
///   it creates two work items: one for the issue itself, and one to
///   improve the heuristic that missed it during real-time detection.
///
/// Runs until the session ends or is no longer reachable.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub fn execute_session_watch(
    session_id: &str,
    project_dir: &Path,
    poll_interval_seconds: u64,
    json: bool,
    actor_id: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = WatchCycleState {
        realtime_seen: HashSet::new(),
        total_issues: 0,
        cycle_count: 0,
        tail_states: HashMap::new(),
        shared_cross_agent_editors: HashMap::new(),
    };

    loop {
        if !watch_cycle(session_id, project_dir, json, actor_id, &mut state)? {
            break;
        }
        thread::sleep(Duration::from_secs(poll_interval_seconds));
    }

    Ok(i32::from(state.total_issues > 0))
}

/// Run the continuous multi-agent observation loop on an async task.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub async fn execute_session_watch_async(
    session_id: &str,
    project_dir: &Path,
    poll_interval_seconds: u64,
    json: bool,
    actor_id: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = WatchCycleState {
        realtime_seen: HashSet::new(),
        total_issues: 0,
        cycle_count: 0,
        tail_states: HashMap::new(),
        shared_cross_agent_editors: HashMap::new(),
    };

    loop {
        if !watch_cycle(session_id, project_dir, json, actor_id, &mut state)? {
            break;
        }
        sleep(Duration::from_secs(poll_interval_seconds)).await;
    }

    Ok(i32::from(state.total_issues > 0))
}

fn watch_cycle(
    session_id: &str,
    project_dir: &Path,
    json: bool,
    actor_id: Option<&str>,
    cycle: &mut WatchCycleState,
) -> Result<bool, CliError> {
    let Ok(state) = service::session_status(session_id, project_dir) else {
        return Ok(false);
    };
    if state.status != SessionStatus::Active {
        return Ok(false);
    }

    let _ = service::sync_agent_liveness(session_id, project_dir);

    let Ok(state) = service::session_status(session_id, project_dir) else {
        return Ok(false);
    };

    let issues = scan_all_agents_incremental(
        &state,
        session_id,
        project_dir,
        &mut cycle.tail_states,
        &mut cycle.shared_cross_agent_editors,
    )?;
    let new_issues: Vec<Issue> = issues
        .into_iter()
        .filter(|issue| cycle.realtime_seen.insert(issue.fingerprint.clone()))
        .collect();

    if !new_issues.is_empty() {
        cycle.total_issues += new_issues.len();
        create_work_items_for_issues(&new_issues, session_id, &state, project_dir, actor_id)?;
        emit_watch_issues(&new_issues, json);
    }
    persist_observer_snapshot(&state, project_dir, &new_issues)?;

    cycle.cycle_count += 1;
    if cycle.cycle_count.is_multiple_of(SWEEP_CYCLE_COUNT) {
        run_periodic_sweep(
            session_id,
            project_dir,
            &state,
            &cycle.realtime_seen,
            &mut cycle.total_issues,
            json,
            actor_id,
        )?;
    }

    Ok(true)
}

fn run_periodic_sweep(
    session_id: &str,
    project_dir: &Path,
    state: &SessionState,
    realtime_seen: &HashSet<String>,
    total_issues: &mut usize,
    json: bool,
    actor_id: Option<&str>,
) -> Result<(), CliError> {
    let sweep_issues = scan_all_agents(state, session_id, project_dir)?;
    let missed: Vec<&Issue> = sweep_issues
        .iter()
        .filter(|issue| !realtime_seen.contains(&issue.fingerprint))
        .collect();
    let missed_issues: Vec<Issue> = missed.into_iter().cloned().collect();

    if missed_issues.is_empty() {
        return Ok(());
    }
    persist_observer_snapshot(state, project_dir, &missed_issues)?;

    let Some(actor) = actor_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(());
    };

    for issue in &missed_issues {
        *total_issues += 1;

        let title = format!("[{}] {}", issue.code, issue.summary);
        let spec = TaskSpec {
            title: &title,
            context: Some(&issue.details),
            severity: task_severity_for_issue(issue),
            suggested_fix: issue.fix_hint.as_deref(),
            source: TaskSource::Observe,
            observe_issue_id: Some(&issue.id),
        };
        let _ = service::create_task_with_source(session_id, &spec, actor, project_dir);

        let heuristic_title = format!(
            "[heuristic_gap] Real-time missed {} at line {}",
            issue.code, issue.line,
        );
        let heuristic_context = format!(
            "The periodic sweep caught issue '{}' (code: {}) at line {} that the \
             real-time watcher did not detect. Investigate why the real-time \
             classification path missed this pattern and add a rule or check.",
            issue.summary, issue.code, issue.line,
        );
        let heuristic_spec = TaskSpec {
            title: &heuristic_title,
            context: Some(&heuristic_context),
            severity: TaskSeverity::Low,
            suggested_fix: None,
            source: TaskSource::Observe,
            observe_issue_id: None,
        };
        let _ = service::create_task_with_source(session_id, &heuristic_spec, actor, project_dir);
    }

    emit_watch_issues(&missed_issues, json);
    Ok(())
}
