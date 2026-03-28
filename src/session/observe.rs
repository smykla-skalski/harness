use std::collections::HashSet;
use std::path::Path;

use crate::agents::runtime;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::observe::classifier::classify_line;
use crate::observe::types::{Issue, IssueSeverity, ScanState};

use super::service;
use super::types::{SessionState, TaskSeverity};

/// Run the multi-agent observation loop for a session.
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
    let mut all_issues: Vec<Issue> = Vec::new();

    for agent in state.agents.values() {
        let agent_runtime = resolve_agent_runtime(&agent.runtime);
        let Some(agent_runtime) = agent_runtime else {
            continue;
        };
        let issues = scan_agent_log(agent_runtime, &agent.agent_id, session_id, project_dir)?;
        all_issues.extend(issues);
    }

    dedup_issues(&mut all_issues);
    create_work_items_for_issues(&all_issues, session_id, &state, project_dir);

    if json {
        let json_output = serde_json::to_string_pretty(&all_issues)
            .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
        println!("{json_output}");
    } else {
        for issue in &all_issues {
            println!(
                "[{:?}] {} - {} (line {})",
                issue.severity, issue.code, issue.summary, issue.line,
            );
        }
    }

    Ok(i32::from(!all_issues.is_empty()))
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
    _session_id: &str,
    project_dir: &Path,
) -> Result<Vec<Issue>, CliError> {
    let log_path = agent_runtime.discover_native_log(agent_id, project_dir)?;
    let Some(log_path) = log_path else {
        return Ok(Vec::new());
    };
    let content = fs_err::read_to_string(&log_path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read agent log {}: {error}",
            log_path.display()
        ))
    })?;

    let mut scan_state = ScanState::default();
    scan_state.agent_id = Some(agent_id.to_string());

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
