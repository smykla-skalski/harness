use super::*;

pub(super) fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("test-service"), || {
            let project = tmp.path().join("project");
            test_fn(&project);
        });
    });
}

pub(super) fn find_agent_by_runtime<'a>(
    state: &'a SessionState,
    runtime: &str,
) -> &'a AgentRegistration {
    state
        .agents
        .values()
        .find(|agent| agent.runtime == runtime)
        .unwrap_or_else(|| panic!("no agent with runtime '{runtime}'"))
}

pub(super) fn set_log_mtime_seconds_ago(path: &std::path::Path, seconds: u64) {
    let old_time = std::time::SystemTime::now() - std::time::Duration::from_secs(seconds);
    std::fs::File::options()
        .write(true)
        .open(path)
        .expect("open for mtime")
        .set_times(std::fs::FileTimes::new().set_modified(old_time))
        .expect("set mtime");
}

pub(super) fn age_agent_activity(project: &Path, session_id: &str, agent_id: &str, seconds: i64) {
    let stale = (chrono::Utc::now() - chrono::Duration::seconds(seconds)).to_rfc3339();
    let layout = storage::layout_from_project_dir(project, session_id).expect("layout");
    storage::update_state(&layout, |state| {
        let agent = state.agents.get_mut(agent_id).expect("agent");
        agent.last_activity_at = Some(stale.clone());
        agent.updated_at = stale.clone();
        Ok(())
    })
    .expect("age agent activity");
}

pub(super) fn write_agent_log_file(project: &Path, runtime: &str, session_id: &str) -> PathBuf {
    let log_path = crate::workspace::project_context_dir(project)
        .join(format!("agents/sessions/{runtime}/{session_id}/raw.jsonl"));
    fs_err::create_dir_all(log_path.parent().unwrap()).expect("dirs");
    fs_err::write(&log_path, "{}\n").expect("write log");
    log_path
}
