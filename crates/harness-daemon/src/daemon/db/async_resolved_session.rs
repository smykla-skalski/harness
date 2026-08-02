use tokio::task::spawn_blocking;

use super::{
    AsyncDaemonDb, CliError, DiscoveredProject, PathBuf, SessionState, daemon_index, db_error,
};
use crate::session::service::canonicalize_persisted_session_state;
use crate::workspace::utc_now;

#[derive(sqlx::FromRow)]
pub(super) struct AsyncResolvedSessionRow {
    state_json: String,
    project_id: String,
    project_name: String,
    project_dir: Option<String>,
    repository_root: Option<String>,
    checkout_id: String,
    checkout_name: String,
    context_root: String,
    is_worktree: bool,
    worktree_name: Option<String>,
}

impl AsyncResolvedSessionRow {
    pub(super) async fn into_resolved_session(
        self,
        db: &AsyncDaemonDb,
    ) -> Result<daemon_index::ResolvedSession, CliError> {
        let (resolved, canonicalized) = parse_on_blocking_stack(self).await?;
        if canonicalized {
            db.save_session_state(&resolved.project.project_id, &resolved.state)
                .await?;
        }
        Ok(resolved)
    }
}

async fn parse_on_blocking_stack(
    row: AsyncResolvedSessionRow,
) -> Result<(daemon_index::ResolvedSession, bool), CliError> {
    spawn_blocking(move || parse_resolved_session(row))
        .await
        .map_err(|error| db_error(format!("join async session state parser: {error}")))?
}

fn parse_resolved_session(
    row: AsyncResolvedSessionRow,
) -> Result<(daemon_index::ResolvedSession, bool), CliError> {
    let mut state: SessionState = serde_json::from_str(&row.state_json)
        .map_err(|error| db_error(format!("parse session state: {error}")))?;
    let project = DiscoveredProject {
        project_id: row.project_id,
        name: row.project_name,
        project_dir: row.project_dir.as_deref().map(PathBuf::from),
        repository_root: row.repository_root.as_deref().map(PathBuf::from),
        checkout_id: row.checkout_id,
        checkout_name: row.checkout_name,
        context_root: PathBuf::from(row.context_root),
        is_worktree: row.is_worktree,
        worktree_name: row.worktree_name,
    };
    let canonicalized = canonicalize_persisted_session_state(&mut state, &utc_now());
    Ok((
        daemon_index::ResolvedSession { project, state },
        canonicalized,
    ))
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::process::{Command, Output};
    use std::thread;

    use serde_json::json;
    use tokio::runtime::Builder as RuntimeBuilder;

    use super::*;

    const PARSE_STACK_CHILD_ENV: &str = "HARNESS_TEST_SESSION_PARSE_STACK_CHILD";
    const PARSE_STACK_TEST: &str = "daemon::db::async_resolved_session::tests::session_state_deserialization_runs_on_blocking_stack";
    const CONSTRAINED_PARSE_STACK: usize = 128 * 1024;
    const STACK_PRESSURE_DEPTH: usize = 16;

    #[test]
    fn session_state_deserialization_runs_on_blocking_stack() {
        if env::var_os(PARSE_STACK_CHILD_ENV).is_none() {
            let inline = run_parse_stack_child("inline");
            assert!(
                !inline.status.success()
                    && String::from_utf8_lossy(&inline.stderr).contains("stack overflow"),
                "inline parsing did not reproduce the stack overflow: stdout={} stderr={}",
                String::from_utf8_lossy(&inline.stdout),
                String::from_utf8_lossy(&inline.stderr),
            );
            let isolated = run_parse_stack_child("isolated");
            assert!(
                isolated.status.success(),
                "isolated parsing failed: stdout={} stderr={}",
                String::from_utf8_lossy(&isolated.stdout),
                String::from_utf8_lossy(&isolated.stderr),
            );
            return;
        }

        let mode = env::var(PARSE_STACK_CHILD_ENV).expect("session parse stack child mode");
        let row = resolved_row_with_task();
        let runtime = (mode == "isolated").then(|| {
            RuntimeBuilder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
                .expect("session parse runtime")
        });
        let pressure_depth = if mode == "inline" {
            STACK_PRESSURE_DEPTH
        } else {
            0
        };
        let worker = thread::Builder::new()
            .name("constrained-session-parse".into())
            .stack_size(CONSTRAINED_PARSE_STACK)
            .spawn(move || parse_under_stack_pressure(row, runtime.as_ref(), pressure_depth))
            .expect("spawn constrained session parser");
        worker
            .join()
            .expect("constrained session parser")
            .expect("parse session state");
    }

    #[inline(never)]
    fn parse_under_stack_pressure(
        row: AsyncResolvedSessionRow,
        runtime: Option<&tokio::runtime::Runtime>,
        depth: usize,
    ) -> Result<(), CliError> {
        let padding = [0_u8; 4 * 1024];
        std::hint::black_box(&padding);
        let result = if depth == 0 {
            match runtime {
                Some(runtime) => runtime.block_on(parse_on_blocking_stack(row)).map(|_| ()),
                None => parse_resolved_session(row).map(|_| ()),
            }
        } else {
            parse_under_stack_pressure(row, runtime, depth - 1)
        };
        std::hint::black_box(&padding);
        result
    }

    fn run_parse_stack_child(mode: &str) -> Output {
        Command::new(env::current_exe().expect("current test executable"))
            .args(["--exact", PARSE_STACK_TEST, "--nocapture"])
            .env(PARSE_STACK_CHILD_ENV, mode)
            .output()
            .expect("run session parse stack test")
    }

    fn resolved_row_with_task() -> AsyncResolvedSessionRow {
        AsyncResolvedSessionRow {
            state_json: json!({
                "schema_version": 14,
                "session_id": "6a5f202d-c28a-4f0a-940c-fadc118e1fa6",
                "context": "Process one dependency update",
                "status": "awaiting_leader",
                "created_at": "2026-08-01T20:54:11Z",
                "updated_at": "2026-08-01T20:54:11Z",
                "tasks": {
                    "task-board-3f6a419b257741a1af80426b5d057ab1": {
                        "task_id": "task-board-3f6a419b257741a1af80426b5d057ab1",
                        "title": "Process Renovate PR #1332: http 1.5.0",
                        "severity": "high",
                        "status": "open",
                        "created_at": "2026-08-01T20:54:11Z",
                        "updated_at": "2026-08-01T20:54:11Z"
                    }
                }
            })
            .to_string(),
            project_id: "project-harness".into(),
            project_name: "harness".into(),
            project_dir: Some("/tmp/harness".into()),
            repository_root: Some("/tmp/harness".into()),
            checkout_id: "checkout-harness".into(),
            checkout_name: "harness".into(),
            context_root: "/tmp/harness".into(),
            is_worktree: false,
            worktree_name: None,
        }
    }
}
