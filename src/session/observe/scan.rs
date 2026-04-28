use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};
use std::mem;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::agents::runtime;
use crate::errors::{CliError, CliErrorKind};
use crate::observe::classifier::classify_line;
use crate::observe::types::{Issue, ScanState};
use crate::session::service;
use crate::session::types::SessionState;

#[derive(Debug)]
pub(crate) struct AgentLogTailState {
    log_path: PathBuf,
    pub(crate) offset: u64,
    next_line_index: usize,
    scan_state: ScanState,
}

pub(super) struct AgentLogScanTarget<'a> {
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

pub(crate) fn scan_all_agents(
    state: &SessionState,
    session_id: &str,
    project_dir: &Path,
) -> Result<Vec<Issue>, CliError> {
    let mut all_issues: Vec<Issue> = Vec::new();
    let mut shared_cross_agent_editors: HashMap<String, HashSet<String>> = HashMap::new();
    for agent in state.agents.values() {
        let Some(agent_runtime) = resolve_agent_runtime(agent.runtime.runtime_name()) else {
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

pub(crate) fn scan_all_agents_incremental(
    state: &SessionState,
    session_id: &str,
    project_dir: &Path,
    tail_states: &mut HashMap<String, AgentLogTailState>,
    shared_cross_agent_editors: &mut HashMap<String, HashSet<String>>,
) -> Result<Vec<Issue>, CliError> {
    let mut all_issues: Vec<Issue> = Vec::new();
    for agent in state.agents.values() {
        let Some(agent_runtime) = resolve_agent_runtime(agent.runtime.runtime_name()) else {
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

pub(super) fn resolve_agent_runtime(
    runtime_name: &str,
) -> Option<&'static dyn runtime::AgentRuntime> {
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
    let content = fs::read_to_string(&log_path).map_err(|error| {
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
    let metadata = fs::metadata(log_path).map_err(|error| {
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
    let mut file = fs::File::open(log_path).map_err(|error| {
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
