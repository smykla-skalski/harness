use std::collections::{HashMap, HashSet};
use std::mem;
use std::path::Path;
use std::thread;
use std::time::Duration;

use crate::agents::runtime;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;
use crate::observe::classifier::classify_line;
use crate::observe::types::{Issue, IssueSeverity, ScanState};

use super::service;
use super::types::{SessionState, TaskSeverity, TaskSource};

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
    actor_id: Option<&str>,
) -> Result<i32, CliError> {
    let all_issues = run_session_observe(session_id, project_dir, actor_id)?;
    emit_results(&all_issues, json)
}

/// Run a one-shot observe scan and persist any new work items without emitting CLI output.
///
/// # Errors
/// Returns `CliError` if the session is not found or on I/O failures.
pub(crate) fn run_session_observe(
    session_id: &str,
    project_dir: &Path,
    actor_id: Option<&str>,
) -> Result<Vec<Issue>, CliError> {
    let state = service::session_status(session_id, project_dir)?;
    let all_issues = scan_all_agents(&state, session_id, project_dir)?;
    create_work_items_for_issues(&all_issues, session_id, &state, project_dir, actor_id)?;
    Ok(all_issues)
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
    let mut realtime_seen: HashSet<String> = HashSet::new();
    let mut total_issues = 0_usize;
    let mut cycle_count = 0_u64;

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
            .filter(|issue| realtime_seen.insert(issue.fingerprint.clone()))
            .collect();

        if !new_issues.is_empty() {
            total_issues += new_issues.len();
            create_work_items_for_issues(&new_issues, session_id, &state, project_dir, actor_id)?;
            emit_watch_issues(&new_issues, json);
        }

        cycle_count += 1;
        if cycle_count.is_multiple_of(SWEEP_CYCLE_COUNT) {
            run_periodic_sweep(
                session_id,
                project_dir,
                &state,
                &realtime_seen,
                &mut total_issues,
                json,
                actor_id,
            )?;
        }

        thread::sleep(Duration::from_secs(poll_interval_seconds));
    }

    Ok(i32::from(total_issues > 0))
}

/// How many polling cycles between periodic sweeps.
/// With default 3s poll interval, sweep runs every ~5 minutes.
const SWEEP_CYCLE_COUNT: u64 = 100;

/// Periodic sweep: re-scans all agents from scratch and compares with
/// what real-time detection found. Issues caught only by the sweep
/// get two work items: one for the issue, one to improve the heuristic.
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

    if missed.is_empty() {
        return Ok(());
    }

    let Some(actor) = actor_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(());
    };

    for issue in &missed {
        *total_issues += 1;
        let severity = map_severity(issue.severity);

        // Work item 1: the issue itself
        let title = format!("[{}] {}", issue.code, issue.summary);
        let _ = service::create_task_with_source(
            session_id,
            &title,
            Some(&issue.details),
            severity,
            issue.fix_hint.as_deref(),
            TaskSource::Observe,
            Some(&issue.id),
            actor,
            project_dir,
        );

        // Work item 2: improve the heuristic that missed it
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
        let _ = service::create_task_with_source(
            session_id,
            &heuristic_title,
            Some(&heuristic_context),
            TaskSeverity::Low,
            None,
            TaskSource::Observe,
            None,
            actor,
            project_dir,
        );
    }

    emit_watch_issues(&missed.iter().copied().cloned().collect::<Vec<_>>(), json);
    Ok(())
}

fn emit_watch_issues(issues: &[Issue], json: bool) {
    for issue in issues {
        if json {
            let line = serde_json::to_string(issue).unwrap_or_default();
            println!("{line}");
        } else {
            println!(
                "[{:?}] {} - {} (line {})",
                issue.severity, issue.code, issue.summary, issue.line,
            );
        }
    }
}

fn map_severity(severity: IssueSeverity) -> TaskSeverity {
    match severity {
        IssueSeverity::Critical => TaskSeverity::Critical,
        IssueSeverity::Medium => TaskSeverity::Medium,
        IssueSeverity::Low => TaskSeverity::Low,
    }
}

fn scan_all_agents(
    state: &SessionState,
    session_id: &str,
    project_dir: &Path,
) -> Result<Vec<Issue>, CliError> {
    let mut all_issues: Vec<Issue> = Vec::new();
    let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();
    for agent in state.agents.values() {
        let Some(agent_runtime) = resolve_agent_runtime(&agent.runtime) else {
            continue;
        };
        let Some(agent_session_id) = agent.agent_session_id.as_deref() else {
            continue;
        };
        let role_label = format!("{:?}", agent.role).to_lowercase();
        let issues = scan_agent_log(
            agent_runtime,
            &agent.agent_id,
            agent_session_id,
            session_id,
            Some(&role_label),
            project_dir,
            &mut shared_cross_agent_editors,
        )?;
        all_issues.extend(issues);
    }
    dedup_issues(&mut all_issues);
    Ok(all_issues)
}

fn emit_results(issues: &[Issue], json: bool) -> Result<i32, CliError> {
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
    agent_session_id: &str,
    session_id: &str,
    agent_role: Option<&str>,
    project_dir: &Path,
    shared_cross_agent_editors: &mut HashMap<String, HashSet<String>>,
) -> Result<Vec<Issue>, CliError> {
    let Some(log_path) = agent_runtime.discover_native_log(agent_session_id, project_dir)? else {
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
    scan_state.cross_agent_editors = mem::take(shared_cross_agent_editors);

    let mut issues = Vec::new();
    for (index, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        issues.extend(classify_line(index, line, &mut scan_state));
    }
    *shared_cross_agent_editors = scan_state.cross_agent_editors;
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
    actor_id: Option<&str>,
) -> Result<(), CliError> {
    let Some(actor_id) = actor_id.filter(|value| !value.trim().is_empty()) else {
        return Ok(());
    };
    let mut known_titles: HashSet<String> = state
        .tasks
        .values()
        .map(|task| task.title.clone())
        .collect();

    for issue in issues {
        let title = format!("[{}] {}", issue.code, issue.summary);
        if !known_titles.insert(title.clone()) {
            continue;
        }
        let severity = match issue.severity {
            IssueSeverity::Critical => TaskSeverity::Critical,
            IssueSeverity::Medium => TaskSeverity::Medium,
            IssueSeverity::Low => TaskSeverity::Low,
        };
        let _ = service::create_task_with_source(
            session_id,
            &title,
            Some(&issue.details),
            severity,
            issue.fix_hint.as_deref(),
            TaskSource::Observe,
            Some(&issue.id),
            actor_id,
            project_dir,
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use fs_err as fs;

    use crate::observe::types::{Confidence, FixSafety, IssueCategory, IssueCode, MessageRole};
    use crate::session::types::SessionRole;
    use crate::workspace::project_context_dir;

    use super::*;

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempfile::tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("xdg path")),
                ),
                ("CLAUDE_SESSION_ID", Some("leader-session")),
            ],
            || {
                let project = tmp.path().join("project");
                fs::create_dir_all(&project).expect("create project dir");
                test_fn(&project);
            },
        );
    }

    fn write_agent_log_lines(
        project_dir: &Path,
        runtime: HookAgent,
        session_id: &str,
        lines: &[serde_json::Value],
    ) {
        let log_path = project_context_dir(project_dir)
            .join("agents/sessions")
            .join(runtime::runtime_for(runtime).name())
            .join(session_id)
            .join("raw.jsonl");
        fs::create_dir_all(
            log_path
                .parent()
                .expect("raw agent log should always have a parent"),
        )
        .expect("create agent log directory");
        let content = lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        fs::write(&log_path, content).expect("write agent log");
    }

    fn write_agent_log(project_dir: &Path, runtime: HookAgent, session_id: &str, text: &str) {
        write_agent_log_lines(
            project_dir,
            runtime,
            session_id,
            &[serde_json::json!({
                "timestamp": "2026-03-28T12:00:00Z",
                "message": {
                    "role": "assistant",
                    "content": text,
                }
            })],
        );
    }

    fn infrastructure_issue(fingerprint: &str) -> Issue {
        Issue {
            id: format!("issue-{fingerprint}"),
            line: 10,
            code: IssueCode::HarnessInfrastructureMisconfiguration,
            category: IssueCategory::WorkflowError,
            severity: IssueSeverity::Critical,
            confidence: Confidence::High,
            fix_safety: FixSafety::TriageRequired,
            summary: "Harness infrastructure misconfiguration detected".to_string(),
            details: "Observe found a runtime/session transcript issue".to_string(),
            fingerprint: fingerprint.to_string(),
            source_role: MessageRole::Assistant,
            source_tool: None,
            fix_target: Some("skills/observe/SKILL.md".to_string()),
            fix_hint: None,
            evidence_excerpt: Some("This is a harness infrastructure issue".to_string()),
        }
    }

    #[test]
    fn observe_scans_logs_via_runtime_session_id() {
        with_temp_project(|project| {
            let state =
                service::start_session("observe test", project, Some("claude"), Some("sess-1"))
                    .expect("start session");

            temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                let joined = service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                )
                .expect("join codex worker");
                let worker = joined
                    .agents
                    .values()
                    .find(|agent| agent.runtime == "codex")
                    .expect("codex worker should be registered");
                assert_ne!(worker.agent_id, "worker-session");
            });

            write_agent_log(
                project,
                HookAgent::Codex,
                "worker-session",
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            let state = service::session_status("sess-1", project).expect("load session status");
            let issues = scan_all_agents(&state, "sess-1", project).expect("scan session logs");

            assert!(
                !issues.is_empty(),
                "expected observe to find transcript issues"
            );
        });
    }

    #[test]
    fn observe_without_actor_stays_read_only() {
        with_temp_project(|project| {
            service::start_session("observe test", project, Some("claude"), Some("sess-2"))
                .expect("start session");
            write_agent_log(
                project,
                HookAgent::Claude,
                "leader-session",
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            let exit_code =
                execute_session_observe("sess-2", project, true, None).expect("observe succeeds");

            assert_eq!(exit_code, 1);
            assert!(
                service::list_tasks("sess-2", None, project)
                    .expect("list tasks")
                    .is_empty(),
                "observe without --actor must not create tasks",
            );
        });
    }

    #[test]
    fn observe_deduplicates_titles_created_in_same_pass() {
        with_temp_project(|project| {
            let state =
                service::start_session("observe test", project, Some("claude"), Some("sess-3"))
                    .expect("start session");
            let leader_id = state.leader_id.clone().expect("leader id");
            let issues = vec![
                infrastructure_issue("fingerprint-a"),
                infrastructure_issue("fingerprint-b"),
            ];

            create_work_items_for_issues(&issues, "sess-3", &state, project, Some(&leader_id))
                .expect("create deduplicated tasks");

            let tasks = service::list_tasks("sess-3", None, project).expect("list tasks");
            assert_eq!(tasks.len(), 1);
            assert_eq!(
                tasks[0].severity,
                TaskSeverity::Critical,
                "task severity should follow the issue severity",
            );
        });
    }

    #[test]
    fn observe_detects_cross_agent_file_conflicts_across_agents() {
        with_temp_project(|project| {
            let state =
                service::start_session("observe test", project, Some("claude"), Some("sess-4"))
                    .expect("start session");

            temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                )
                .expect("join codex worker");
            });

            write_agent_log_lines(
                project,
                HookAgent::Claude,
                "leader-session",
                &[
                    serde_json::json!({
                        "timestamp": "2026-03-28T12:00:00Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "id": "write-1",
                                "name": "Write",
                                "input": { "file_path": "src/shared.rs", "content": "leader edit" }
                            }]
                        }
                    }),
                    serde_json::json!({
                        "timestamp": "2026-03-28T12:00:01Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_result",
                                "tool_use_id": "write-1",
                                "content": "The file src/shared.rs has been updated successfully"
                            }]
                        }
                    }),
                ],
            );
            write_agent_log_lines(
                project,
                HookAgent::Codex,
                "worker-session",
                &[
                    serde_json::json!({
                        "timestamp": "2026-03-28T12:00:02Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "id": "write-2",
                                "name": "Write",
                                "input": { "file_path": "src/shared.rs", "content": "worker edit" }
                            }]
                        }
                    }),
                    serde_json::json!({
                        "timestamp": "2026-03-28T12:00:03Z",
                        "message": {
                            "role": "assistant",
                            "content": [{
                                "type": "tool_result",
                                "tool_use_id": "write-2",
                                "content": "The file src/shared.rs has been updated successfully"
                            }]
                        }
                    }),
                ],
            );

            let observed = service::session_status("sess-4", project).expect("load session");
            let issues = scan_all_agents(&observed, "sess-4", project).expect("scan logs");

            assert!(
                issues
                    .iter()
                    .any(|issue| issue.code == IssueCode::CrossAgentFileConflict),
                "expected cross-agent conflict issue from shared editor state",
            );
        });
    }
}
