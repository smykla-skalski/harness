use std::collections::HashSet;
use std::path::Path;
use std::thread;
use std::time::Duration;

use crate::agents::runtime;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::observe::classifier::classify_line;
use crate::observe::types::{Issue, IssueSeverity, ScanState};

use super::service;
use super::types::{SessionState, TaskSeverity};

/// Run a one-shot multi-agent observation scan.
///
/// Scans each registered agent's conversation log using the existing
/// classifier pipeline, merges issues across agents, and creates work
/// items in the session state for new issues.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub fn execute_session_observe(
    session_id: &str,
    project_dir: &Path,
    json: bool,
) -> Result<i32, CliError> {
    let state = service::session_status(session_id, project_dir)?;
    let all_issues = scan_all_agents(&state, session_id, project_dir)?;
    emit_results(&all_issues, session_id, &state, project_dir, json)
}

/// Run the continuous multi-agent observation loop.
///
/// Polls each agent's log at the given interval, classifying new lines
/// and creating work items for detected issues. Runs until interrupted.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub fn execute_session_watch(
    session_id: &str,
    project_dir: &Path,
    poll_interval_seconds: u64,
    json: bool,
) -> Result<i32, CliError> {
    let mut cursors: HashSet<String> = HashSet::new();
    let mut total_issues = 0_usize;

    loop {
        let Ok(state) = service::session_status(session_id, project_dir) else {
            break;
        };
        if state.status != super::types::SessionStatus::Active {
            break;
        }

        let issues = scan_all_agents(&state, session_id, project_dir)?;
        let new_issues: Vec<Issue> = issues
            .into_iter()
            .filter(|issue| cursors.insert(issue.fingerprint.clone()))
            .collect();

        if !new_issues.is_empty() {
            total_issues += new_issues.len();
            create_work_items_for_issues(&new_issues, session_id, &state, project_dir);
            if json {
                for issue in &new_issues {
                    let line = serde_json::to_string(issue).unwrap_or_default();
                    println!("{line}");
                }
            } else {
                for issue in &new_issues {
                    println!(
                        "[{:?}] {} - {} (line {})",
                        issue.severity, issue.code, issue.summary, issue.line,
                    );
                }
            }
        }

        thread::sleep(Duration::from_secs(poll_interval_seconds));
    }

    Ok(i32::from(total_issues > 0))
}

fn scan_all_agents(
    state: &SessionState,
    session_id: &str,
    project_dir: &Path,
) -> Result<Vec<Issue>, CliError> {
    let mut all_issues: Vec<Issue> = Vec::new();
    for agent in state.agents.values() {
        let Some(agent_runtime) = resolve_agent_runtime(&agent.runtime) else {
            continue;
        };
        let role_label = format!("{:?}", agent.role).to_lowercase();
        let issues = scan_agent_log(
            agent_runtime,
            &agent.agent_id,
            session_id,
            Some(&role_label),
            project_dir,
        )?;
        all_issues.extend(issues);
    }
    dedup_issues(&mut all_issues);
    Ok(all_issues)
}

fn emit_results(
    issues: &[Issue],
    session_id: &str,
    state: &SessionState,
    project_dir: &Path,
    json: bool,
) -> Result<i32, CliError> {
    create_work_items_for_issues(issues, session_id, state, project_dir);
    if json {
        let json_output = serde_json::to_string_pretty(issues)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        println!("{json_output}");
    } else {
        for issue in issues {
            println!(
                "[{:?}] {} - {} (line {})",
                issue.severity, issue.code, issue.summary, issue.line,
            );
        }
    }
    Ok(i32::from(!issues.is_empty()))
}

fn resolve_agent_runtime(runtime_name: &str) -> Option<&'static dyn runtime::AgentRuntime> {
    let agent = match runtime_name {
        "claude" => HookAgent::Claude,
        "codex" => HookAgent::Codex,
        "gemini" => HookAgent::Gemini,
        "copilot" => HookAgent::Copilot,
        "opencode" => HookAgent::OpenCode,
        _ => return None,
    };
    Some(runtime::runtime_for(agent))
}

fn scan_agent_log(
    agent_runtime: &dyn runtime::AgentRuntime,
    agent_id: &str,
    session_id: &str,
    agent_role: Option<&str>,
    project_dir: &Path,
) -> Result<Vec<Issue>, CliError> {
    let Some(log_path) = agent_runtime.discover_native_log(agent_id, project_dir)? else {
        return Ok(Vec::new());
    };
    let content = fs_err::read_to_string(&log_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("read agent log {}: {error}", log_path.display()))
    })?;

    let mut scan_state = ScanState {
        agent_id: Some(agent_id.to_string()),
        agent_role: agent_role.map(ToString::to_string),
        orchestration_session_id: Some(session_id.to_string()),
        ..ScanState::default()
    };

    let mut issues = Vec::new();
    for (index, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        issues.extend(classify_line(index, line, &mut scan_state));
    }
    Ok(issues)
}

fn dedup_issues(issues: &mut Vec<Issue>) {
    let mut seen = HashSet::new();
    issues.retain(|issue| seen.insert(issue.fingerprint.clone()));
}

fn create_work_items_for_issues(
    issues: &[Issue],
    session_id: &str,
    state: &SessionState,
    project_dir: &Path,
) {
    let leader_id = state.leader_id.as_deref().unwrap_or("observer");

    for issue in issues {
        let title = format!("[{}] {}", issue.code, issue.summary);
        let existing = state.tasks.values().any(|task| task.title == title);
        if existing {
            continue;
        }
        let severity = match issue.severity {
            IssueSeverity::Critical => TaskSeverity::Critical,
            IssueSeverity::Medium => TaskSeverity::Medium,
            IssueSeverity::Low => TaskSeverity::Low,
        };
        let _ = service::create_task(
            session_id,
            &title,
            Some(&issue.details),
            severity,
            leader_id,
            project_dir,
        );
    }
}
