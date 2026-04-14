use std::path::{Path, PathBuf};

#[must_use]
pub fn signals_root(context_root: &Path) -> PathBuf {
    context_root.join("agents").join("signals")
}

#[must_use]
pub fn agent_transcript_path(context_root: &Path, runtime: &str, session_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("sessions")
        .join(runtime)
        .join(session_id)
        .join("raw.jsonl")
}

#[must_use]
pub fn observe_snapshot_path(context_root: &Path, observe_id: &str) -> PathBuf {
    context_root
        .join("agents")
        .join("observe")
        .join(observe_id)
        .join("snapshot.json")
}

pub(super) fn session_state_path(context_root: &Path, session_id: &str) -> PathBuf {
    context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("state.json")
}

pub(super) fn session_log_path(context_root: &Path, session_id: &str) -> PathBuf {
    context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("log.jsonl")
}

pub(super) fn task_checkpoints_path(
    context_root: &Path,
    session_id: &str,
    task_id: &str,
) -> PathBuf {
    context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("tasks")
        .join(task_id)
        .join("checkpoints.jsonl")
}
