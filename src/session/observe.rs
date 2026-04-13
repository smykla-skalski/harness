use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::mem;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use crate::agents::runtime;
use crate::errors::{CliError, CliErrorKind};
use crate::observe::classifier::classify_line;
use crate::observe::types::{Issue, IssueSeverity, ScanState};
use tokio::time::sleep;

use super::service;
use super::types::{SessionState, TaskSeverity, TaskSource};

#[derive(Debug)]
struct AgentLogTailState {
    log_path: PathBuf,
    offset: u64,
    next_line_index: usize,
    scan_state: ScanState,
}

struct AgentLogScanTarget<'a> {
    agent_runtime: &'a dyn runtime::AgentRuntime,
    agent_id: &'a str,
    agent_session_id: &'a str,
    session_id: &'a str,
    agent_role: Option<&'a str>,
    project_dir: &'a Path,
}

impl AgentLogTailState {
    fn new(log_path: PathBuf, agent_id: &str, agent_role: Option<&str>, session_id: &str) -> Self {
        Self {
            log_path,
            offset: 0,
            next_line_index: 0,
            scan_state: agent_scan_state(agent_id, agent_role, session_id),
        }
    }

    fn reset(
        &mut self,
        log_path: PathBuf,
        agent_id: &str,
        agent_role: Option<&str>,
        session_id: &str,
    ) {
        *self = Self::new(log_path, agent_id, agent_role, session_id);
    }
}

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
    let mut tail_states: HashMap<String, AgentLogTailState> = HashMap::new();
    let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();

    loop {
        let Ok(state) = service::session_status(session_id, project_dir) else {
            break;
        };
        if state.status != super::types::SessionStatus::Active {
            break;
        }

        // Sync agent liveness each cycle so dead agents are detected promptly
        let _ = service::sync_agent_liveness(session_id, project_dir);

        // Re-read state after sync since agent statuses may have changed
        let Ok(state) = service::session_status(session_id, project_dir) else {
            break;
        };

        let issues = scan_all_agents_incremental(
            &state,
            session_id,
            project_dir,
            &mut tail_states,
            &mut shared_cross_agent_editors,
        )?;
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
    let mut realtime_seen: HashSet<String> = HashSet::new();
    let mut total_issues = 0_usize;
    let mut cycle_count = 0_u64;
    let mut tail_states: HashMap<String, AgentLogTailState> = HashMap::new();
    let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();

    loop {
        let Ok(state) = service::session_status(session_id, project_dir) else {
            break;
        };
        if state.status != super::types::SessionStatus::Active {
            break;
        }

        // Sync agent liveness each cycle so dead agents are detected promptly
        let _ = service::sync_agent_liveness(session_id, project_dir);

        // Re-read state after sync since agent statuses may have changed
        let Ok(state) = service::session_status(session_id, project_dir) else {
            break;
        };

        let issues = scan_all_agents_incremental(
            &state,
            session_id,
            project_dir,
            &mut tail_states,
            &mut shared_cross_agent_editors,
        )?;
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

        sleep(Duration::from_secs(poll_interval_seconds)).await;
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
        let spec = service::TaskSpec {
            title: &title,
            context: Some(&issue.details),
            severity,
            suggested_fix: issue.fix_hint.as_deref(),
            source: TaskSource::Observe,
            observe_issue_id: Some(&issue.id),
        };
        let _ = service::create_task_with_source(session_id, &spec, actor, project_dir);

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
        let heuristic_spec = service::TaskSpec {
            title: &heuristic_title,
            context: Some(&heuristic_context),
            severity: TaskSeverity::Low,
            suggested_fix: None,
            source: TaskSource::Observe,
            observe_issue_id: None,
        };
        let _ = service::create_task_with_source(session_id, &heuristic_spec, actor, project_dir);
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
        let agent_session_id = service::agent_runtime_session_id(session_id, agent);
        let role_label = format!("{:?}", agent.role).to_lowercase();
        let target = AgentLogScanTarget {
            agent_runtime,
            agent_id: &agent.agent_id,
            agent_session_id,
            session_id,
            agent_role: Some(&role_label),
            project_dir,
        };
        let issues = scan_agent_log(&target, &mut shared_cross_agent_editors)?;
        all_issues.extend(issues);
    }
    dedup_issues(&mut all_issues);
    Ok(all_issues)
}

fn scan_all_agents_incremental(
    state: &SessionState,
    session_id: &str,
    project_dir: &Path,
    tail_states: &mut HashMap<String, AgentLogTailState>,
    shared_cross_agent_editors: &mut HashMap<String, HashSet<String>>,
) -> Result<Vec<Issue>, CliError> {
    let mut all_issues: Vec<Issue> = Vec::new();
    for agent in state.agents.values() {
        let Some(agent_runtime) = resolve_agent_runtime(&agent.runtime) else {
            continue;
        };
        let agent_session_id = service::agent_runtime_session_id(session_id, agent);
        let role_label = format!("{:?}", agent.role).to_lowercase();
        let target = AgentLogScanTarget {
            agent_runtime,
            agent_id: &agent.agent_id,
            agent_session_id,
            session_id,
            agent_role: Some(&role_label),
            project_dir,
        };
        let issues = scan_agent_log_incremental(&target, tail_states, shared_cross_agent_editors)?;
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
    runtime::runtime_for_name(runtime_name)
}

fn agent_scan_state(agent_id: &str, agent_role: Option<&str>, session_id: &str) -> ScanState {
    ScanState {
        agent_id: Some(agent_id.to_string()),
        agent_role: agent_role.map(ToString::to_string),
        orchestration_session_id: Some(session_id.to_string()),
        ..ScanState::default()
    }
}

fn scan_agent_log(
    target: &AgentLogScanTarget<'_>,
    shared_cross_agent_editors: &mut HashMap<String, HashSet<String>>,
) -> Result<Vec<Issue>, CliError> {
    let Some(log_path) = target
        .agent_runtime
        .discover_native_log(target.agent_session_id, target.project_dir)?
    else {
        return Ok(Vec::new());
    };
    let content = fs_err::read_to_string(&log_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("read agent log {}: {error}", log_path.display()))
    })?;

    let mut scan_state = agent_scan_state(target.agent_id, target.agent_role, target.session_id);
    scan_state.cross_agent_editors = mem::take(shared_cross_agent_editors);

    let mut next_line_index = 0;
    let issues = scan_log_content(&content, &mut next_line_index, &mut scan_state);
    *shared_cross_agent_editors = scan_state.cross_agent_editors;
    Ok(issues)
}

fn scan_agent_log_incremental(
    target: &AgentLogScanTarget<'_>,
    tail_states: &mut HashMap<String, AgentLogTailState>,
    shared_cross_agent_editors: &mut HashMap<String, HashSet<String>>,
) -> Result<Vec<Issue>, CliError> {
    let Some(log_path) = target
        .agent_runtime
        .discover_native_log(target.agent_session_id, target.project_dir)?
    else {
        tail_states.remove(target.agent_id);
        return Ok(Vec::new());
    };
    let tail_state = tail_states
        .entry(target.agent_id.to_string())
        .or_insert_with(|| {
            AgentLogTailState::new(
                log_path.clone(),
                target.agent_id,
                target.agent_role,
                target.session_id,
            )
        });
    sync_tail_state(
        tail_state,
        &log_path,
        target.agent_id,
        target.agent_role,
        target.session_id,
    )?;

    let content = read_agent_log_delta(&log_path, tail_state)?;
    tail_state.scan_state.cross_agent_editors = mem::take(shared_cross_agent_editors);
    let issues = scan_log_content(
        &content,
        &mut tail_state.next_line_index,
        &mut tail_state.scan_state,
    );
    *shared_cross_agent_editors = mem::take(&mut tail_state.scan_state.cross_agent_editors);
    Ok(issues)
}

fn sync_tail_state(
    tail_state: &mut AgentLogTailState,
    log_path: &Path,
    agent_id: &str,
    agent_role: Option<&str>,
    session_id: &str,
) -> Result<(), CliError> {
    let metadata = fs_err::metadata(log_path).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read agent log metadata {}: {error}",
            log_path.display()
        ))
    })?;
    if tail_state.log_path != log_path || metadata.len() < tail_state.offset {
        tail_state.reset(log_path.to_path_buf(), agent_id, agent_role, session_id);
        return Ok(());
    }

    tail_state.scan_state.agent_id = Some(agent_id.to_string());
    tail_state.scan_state.agent_role = agent_role.map(ToString::to_string);
    tail_state.scan_state.orchestration_session_id = Some(session_id.to_string());
    Ok(())
}

fn read_agent_log_delta(
    log_path: &Path,
    tail_state: &mut AgentLogTailState,
) -> Result<String, CliError> {
    let mut file = fs_err::File::open(log_path).map_err(|error| {
        CliErrorKind::workflow_io(format!("open agent log {}: {error}", log_path.display()))
    })?;
    file.seek(SeekFrom::Start(tail_state.offset))
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("seek agent log {}: {error}", log_path.display()))
        })?;
    let mut content = String::new();
    file.read_to_string(&mut content).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read agent log delta {}: {error}",
            log_path.display()
        ))
    })?;
    tail_state.offset = file.stream_position().map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "read agent log position {}: {error}",
            log_path.display()
        ))
    })?;
    Ok(content)
}

fn scan_log_content(
    content: &str,
    next_line_index: &mut usize,
    scan_state: &mut ScanState,
) -> Vec<Issue> {
    let mut issues = Vec::new();
    for (offset, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        issues.extend(classify_line(*next_line_index + offset, line, scan_state));
    }
    *next_line_index += content.lines().count();
    issues
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
        let spec = service::TaskSpec {
            title: &title,
            context: Some(&issue.details),
            severity,
            suggested_fix: issue.fix_hint.as_deref(),
            source: TaskSource::Observe,
            observe_issue_id: Some(&issue.id),
        };
        let _ = service::create_task_with_source(session_id, &spec, actor_id, project_dir)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use fs_err as fs;
    use harness_testkit::with_isolated_harness_env;

    use crate::hooks::adapters::HookAgent;
    use crate::observe::types::{Confidence, FixSafety, IssueCategory, IssueCode, MessageRole};
    use crate::session::types::SessionRole;
    use crate::workspace::project_context_dir;

    use super::*;

    fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
        let tmp = tempfile::tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
                let project = tmp.path().join("project");
                fs::create_dir_all(&project).expect("create project dir");
                test_fn(&project);
            });
        });
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

    fn append_agent_log_lines(
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
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .expect("open agent log for append");
        let content = lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        file.write_all(content.as_bytes())
            .expect("append agent log lines");
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
                service::start_session("observe test", "", project, Some("claude"), Some("sess-1"))
                    .expect("start session");

            temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                let joined = service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
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
    fn observe_scans_logs_via_legacy_session_fallback() {
        with_temp_project(|project| {
            let state = service::start_session(
                "observe test",
                "",
                project,
                Some("claude"),
                Some("sess-legacy"),
            )
            .expect("start session");

            let joined = service::join_session(
                &state.session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                project,
                None,
            )
            .expect("join codex worker");
            let worker = joined
                .agents
                .values()
                .find(|agent| agent.runtime == "codex")
                .expect("codex worker should be registered");
            let worker_id = worker.agent_id.clone();
            crate::session::storage::update_state(project, &state.session_id, |state| {
                state
                    .agents
                    .get_mut(&worker_id)
                    .expect("legacy worker should exist")
                    .agent_session_id = None;
                Ok(())
            })
            .expect("clear worker runtime session id for legacy fixture");

            write_agent_log(
                project,
                HookAgent::Codex,
                &state.session_id,
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            let state =
                service::session_status("sess-legacy", project).expect("load session status");
            let worker = state
                .agents
                .get(&worker_id)
                .expect("legacy worker should be present");
            assert!(worker.agent_session_id.is_none());
            let issues =
                scan_all_agents(&state, "sess-legacy", project).expect("scan legacy session logs");

            assert!(
                !issues.is_empty(),
                "expected observe to find transcript issues for legacy sessions"
            );
        });
    }

    #[test]
    fn incremental_scan_skips_previously_consumed_log_bytes() {
        with_temp_project(|project| {
            let state = service::start_session(
                "observe test",
                "",
                project,
                Some("claude"),
                Some("sess-incremental-1"),
            )
            .expect("start session");
            let leader = state
                .agents
                .values()
                .find(|agent| agent.runtime == "claude")
                .expect("leader agent should exist");

            write_agent_log(
                project,
                HookAgent::Claude,
                "leader-session",
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            let observed = service::session_status("sess-incremental-1", project)
                .expect("load session status");
            let mut tail_states: HashMap<String, AgentLogTailState> = HashMap::new();
            let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();

            let first_issues = scan_all_agents_incremental(
                &observed,
                "sess-incremental-1",
                project,
                &mut tail_states,
                &mut shared_cross_agent_editors,
            )
            .expect("scan new log content");
            assert_eq!(first_issues.len(), 1);
            let first_offset = tail_states
                .get(&leader.agent_id)
                .expect("tail state should be recorded")
                .offset;

            let second_issues = scan_all_agents_incremental(
                &observed,
                "sess-incremental-1",
                project,
                &mut tail_states,
                &mut shared_cross_agent_editors,
            )
            .expect("skip already scanned bytes");

            assert!(
                second_issues.is_empty(),
                "second incremental scan should not reread old log content",
            );
            assert_eq!(
                tail_states
                    .get(&leader.agent_id)
                    .expect("tail state should remain present")
                    .offset,
                first_offset,
                "cursor should stay at the previous end of file when nothing new was appended",
            );
        });
    }

    #[test]
    fn incremental_scan_detects_appended_log_lines() {
        with_temp_project(|project| {
            let state = service::start_session(
                "observe test",
                "",
                project,
                Some("claude"),
                Some("sess-incremental-2"),
            )
            .expect("start session");
            let leader = state
                .agents
                .values()
                .find(|agent| agent.runtime == "claude")
                .expect("leader agent should exist");

            write_agent_log(
                project,
                HookAgent::Claude,
                "leader-session",
                "This is a harness infrastructure issue - the KDS port wasn't forwarded",
            );

            let observed = service::session_status("sess-incremental-2", project)
                .expect("load session status");
            let mut tail_states: HashMap<String, AgentLogTailState> = HashMap::new();
            let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();

            let first_issues = scan_all_agents_incremental(
                &observed,
                "sess-incremental-2",
                project,
                &mut tail_states,
                &mut shared_cross_agent_editors,
            )
            .expect("scan initial log content");
            assert_eq!(first_issues.len(), 1);
            let first_offset = tail_states
                .get(&leader.agent_id)
                .expect("tail state should be recorded")
                .offset;

            append_agent_log_lines(
                project,
                HookAgent::Claude,
                "leader-session",
                &[serde_json::json!({
                    "timestamp": "2026-03-28T12:00:01Z",
                    "message": {
                        "role": "assistant",
                        "content": "The bootstrap is missing the KUMA_MULTIZONE environment variable",
                    }
                })],
            );

            let second_issues = scan_all_agents_incremental(
                &observed,
                "sess-incremental-2",
                project,
                &mut tail_states,
                &mut shared_cross_agent_editors,
            )
            .expect("scan appended log content");

            assert_eq!(second_issues.len(), 1);
            assert!(
                tail_states
                    .get(&leader.agent_id)
                    .expect("tail state should remain present")
                    .offset
                    > first_offset,
                "cursor should advance after new bytes are appended",
            );
        });
    }

    #[test]
    fn runtime_resolution_accepts_vibe_and_opencode() {
        let vibe_runtime = resolve_agent_runtime("vibe").expect("vibe runtime");
        let opencode_runtime = resolve_agent_runtime("opencode").expect("opencode runtime");

        assert_eq!(vibe_runtime.name(), "vibe");
        assert_eq!(opencode_runtime.name(), "opencode");
    }

    #[test]
    fn observe_without_actor_stays_read_only() {
        with_temp_project(|project| {
            service::start_session("observe test", "", project, Some("claude"), Some("sess-2"))
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
                service::start_session("observe test", "", project, Some("claude"), Some("sess-3"))
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
                service::start_session("observe test", "", project, Some("claude"), Some("sess-4"))
                    .expect("start session");

            temp_env::with_vars([("CODEX_SESSION_ID", Some("worker-session"))], || {
                service::join_session(
                    &state.session_id,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    project,
                    None,
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
