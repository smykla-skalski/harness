use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

#[cfg(feature = "daemon-runtime")]
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{ManagedAgentRef, SessionState};
#[cfg(feature = "daemon-runtime")]
use crate::workspace::project_context_dir;

pub(super) type Shared<T> = Arc<Mutex<T>>;

pub(super) fn lock<'a, T>(mutex: &'a Mutex<T>, name: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("{name} lock poisoned: {error}")).into())
}

#[cfg(feature = "daemon-runtime")]
pub(super) fn lock_db(db: &Arc<Mutex<DaemonDb>>) -> Result<MutexGuard<'_, DaemonDb>, CliError> {
    db.lock().map_err(|error| {
        CliErrorKind::workflow_io(format!("daemon database lock poisoned: {error}")).into()
    })
}

pub(super) struct ResolvedTuiProject {
    pub(super) project_dir: PathBuf,
    pub(super) context_root: PathBuf,
}

#[cfg(feature = "daemon-runtime")]
pub(super) fn resolve_tui_project(
    db: &DaemonDb,
    session_id: &str,
    project_dir: Option<&str>,
) -> Result<ResolvedTuiProject, CliError> {
    if let Some(project_dir) = project_dir.filter(|value| !value.trim().is_empty()) {
        let project_dir = PathBuf::from(project_dir);
        return Ok(ResolvedTuiProject {
            context_root: project_context_dir(&project_dir),
            project_dir,
        });
    }

    let resolved = db.resolve_session(session_id)?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("harness session '{session_id}' not found"))
    })?;
    let context_root = resolved.project.context_root;
    let project_dir = resolved
        .project
        .project_dir
        .or(resolved.project.repository_root)
        .unwrap_or_else(|| context_root.clone());
    Ok(ResolvedTuiProject {
        project_dir,
        context_root,
    })
}

#[cfg(feature = "daemon-runtime")]
pub(super) async fn resolve_tui_project_async(
    db: &AsyncDaemonDb,
    session_id: &str,
    project_dir: Option<&str>,
) -> Result<ResolvedTuiProject, CliError> {
    if let Some(project_dir) = project_dir.filter(|value| !value.trim().is_empty()) {
        let project_dir = PathBuf::from(project_dir);
        return Ok(ResolvedTuiProject {
            context_root: project_context_dir(&project_dir),
            project_dir,
        });
    }

    let resolved = db.resolve_session(session_id).await?.ok_or_else(|| {
        CliErrorKind::session_not_active(format!("harness session '{session_id}' not found"))
    })?;
    let context_root = resolved.project.context_root;
    let project_dir = resolved
        .project
        .project_dir
        .or(resolved.project.repository_root)
        .unwrap_or_else(|| context_root.clone());
    Ok(ResolvedTuiProject {
        project_dir,
        context_root,
    })
}

pub(super) fn agent_id_for_tui(state: &SessionState, tui_id: &str) -> Result<String, CliError> {
    let managed_agent = ManagedAgentRef::tui(tui_id);
    if let Some(agent_id) = state.find_session_agent_id_by_managed_agent(&managed_agent) {
        return Ok(agent_id.to_string());
    }

    let marker_capability = format!("agent-tui:{tui_id}");
    state
        .agents
        .values()
        .find(|agent| {
            agent
                .capabilities
                .iter()
                .any(|capability| capability == &marker_capability)
        })
        .map(|agent| agent.agent_id.clone())
        .ok_or_else(|| {
            CliErrorKind::workflow_io(format!(
                "joined agent missing managed-agent ref or legacy TUI marker '{marker_capability}'"
            ))
            .into()
        })
}

pub(super) fn transcript_path(context_root: &Path, runtime: &str, tui_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("tui")
        .join(runtime)
        .join(tui_id)
        .join("output.raw")
}

pub(super) fn persist_transcript(
    path: &Path,
    transcript: &[u8],
    persisted_len: &mut usize,
) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!("create terminal agent transcript dir: {error}"))
        })?;
    }

    if transcript.len() < *persisted_len {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
        })?;
        *persisted_len = transcript.len();
        return Ok(());
    }

    if transcript.len() == *persisted_len {
        if *persisted_len == 0 && !path.exists() {
            fs_err::write(path, transcript).map_err(|error| {
                CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
            })?;
        }
        return Ok(());
    }

    if *persisted_len == 0 || !path.exists() {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
        })?;
    } else {
        let mut file = fs_err::OpenOptions::new()
            .append(true)
            .create(true)
            .open(path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("open terminal agent transcript: {error}"))
            })?;
        file.write_all(&transcript[*persisted_len..])
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("append terminal agent transcript: {error}"))
            })?;
    }

    *persisted_len = transcript.len();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::agent_id_for_tui;
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::service::build_new_session;
    use crate::session::types::{AgentRegistration, AgentStatus, ManagedAgentRef, SessionRole};

    fn sample_agent(
        agent_id: &str,
        capabilities: Vec<String>,
        managed_agent: Option<ManagedAgentRef>,
    ) -> AgentRegistration {
        AgentRegistration {
            agent_id: agent_id.into(),
            name: "Worker".into(),
            runtime: "claude".into(),
            role: SessionRole::Worker,
            capabilities,
            joined_at: "2026-05-06T00:00:00Z".into(),
            updated_at: "2026-05-06T00:00:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: None,
            managed_agent,
            last_activity_at: None,
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        }
    }

    #[test]
    fn agent_id_for_tui_prefers_managed_agent_ref() {
        let mut state = build_new_session(
            "test",
            "test",
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "claude",
            None,
            "now",
        );
        state.agents.insert(
            "agent-1".into(),
            sample_agent("agent-1", Vec::new(), Some(ManagedAgentRef::tui("tui-1"))),
        );

        let agent_id = agent_id_for_tui(&state, "tui-1").expect("resolve agent id");

        assert_eq!(agent_id, "agent-1");
    }

    #[test]
    fn agent_id_for_tui_falls_back_to_legacy_marker_capability() {
        let mut state = build_new_session(
            "test",
            "test",
            "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "claude",
            None,
            "now",
        );
        state.agents.insert(
            "agent-1".into(),
            sample_agent("agent-1", vec!["agent-tui:tui-1".into()], None),
        );

        let agent_id = agent_id_for_tui(&state, "tui-1").expect("resolve legacy agent id");

        assert_eq!(agent_id, "agent-1");
    }
}
