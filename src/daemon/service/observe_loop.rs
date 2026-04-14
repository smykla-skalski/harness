use super::{Path, ObserveLoopState, OBSERVE_RUNTIME, Handle, ObserveLoopRequest, ObserveLoopRegistration, DaemonObserveRuntime, PathBuf, AbortHandle, sync_after_mutation, broadcast_session_snapshot, Duration, CliError, session_observe, Future};

pub(crate) fn start_daemon_observe_loop(
    session_id: &str,
    project_dir: &Path,
    actor_id: Option<&str>,
) -> ObserveLoopState {
    let Some(runtime) = OBSERVE_RUNTIME.get().cloned() else {
        return ObserveLoopState::Unavailable;
    };
    let Ok(handle) = Handle::try_current() else {
        return ObserveLoopState::Unavailable;
    };
    let request = ObserveLoopRequest::new(actor_id);
    let session_id = session_id.to_string();
    let project_dir = project_dir.to_path_buf();

    let (state, stale_handle) = {
        let Ok(mut running_sessions) = runtime.running_sessions.lock() else {
            return ObserveLoopState::Unavailable;
        };
        if let Some(existing) = running_sessions.get(&session_id)
            && existing.request == request
        {
            return ObserveLoopState::AlreadyRunning;
        }

        let (stale_handle, generation) =
            running_sessions
                .get(&session_id)
                .map_or((None, 1), |existing| {
                    (
                        Some(existing.abort_handle.clone()),
                        existing.generation.saturating_add(1),
                    )
                });
        let state = if stale_handle.is_some() {
            ObserveLoopState::Restarted
        } else {
            ObserveLoopState::Started
        };
        let registration_session_id = session_id.clone();
        let abort_handle = spawn_daemon_observe_loop(
            &handle,
            runtime.clone(),
            session_id,
            project_dir,
            request.actor_id.clone(),
            generation,
        );
        running_sessions.insert(
            registration_session_id,
            ObserveLoopRegistration {
                request,
                generation,
                abort_handle,
            },
        );
        (state, stale_handle)
    };

    if let Some(stale_handle) = stale_handle {
        stale_handle.abort();
    }
    state
}

pub(crate) fn spawn_daemon_observe_loop(
    handle: &Handle,
    runtime: DaemonObserveRuntime,
    session_id: String,
    project_dir: PathBuf,
    actor_id: Option<String>,
    generation: u64,
) -> AbortHandle {
    let join_handle = handle.spawn(async move {
        let cleanup_session_id = session_id.clone();
        let result =
            run_daemon_observe_task(session_id, project_dir, runtime.poll_interval, actor_id).await;
        if let Err(error) = result {
            tracing::warn!(
                %error,
                session_id = cleanup_session_id,
                "daemon observe loop exited with error"
            );
        }
        if let Ok(mut running_sessions) = runtime.running_sessions.lock()
            && running_sessions
                .get(&cleanup_session_id)
                .is_some_and(|registration| registration.generation == generation)
        {
            running_sessions.remove(&cleanup_session_id);
        }
        let db_guard = runtime.db.get().and_then(|db| db.lock().ok());
        let db_ref = db_guard.as_deref();
        sync_after_mutation(db_ref, &cleanup_session_id);
        broadcast_session_snapshot(&runtime.sender, &cleanup_session_id, db_ref);
    });
    join_handle.abort_handle()
}

pub(crate) async fn run_daemon_observe_task(
    session_id: String,
    project_dir: PathBuf,
    poll_interval: Duration,
    actor_id: Option<String>,
) -> Result<i32, CliError> {
    run_daemon_observe_task_with(
        session_id,
        project_dir,
        poll_interval,
        actor_id,
        |session_id, project_dir, poll_interval, actor_id| async move {
            session_observe::execute_session_watch_async(
                &session_id,
                &project_dir,
                poll_interval.as_secs().max(1),
                false,
                actor_id.as_deref(),
            )
            .await
        },
    )
    .await
}

pub(crate) async fn run_daemon_observe_task_with<F, Fut>(
    session_id: String,
    project_dir: PathBuf,
    poll_interval: Duration,
    actor_id: Option<String>,
    observe_task: F,
) -> Result<i32, CliError>
where
    F: FnOnce(String, PathBuf, Duration, Option<String>) -> Fut + Send,
    Fut: Future<Output = Result<i32, CliError>> + Send,
{
    observe_task(session_id, project_dir, poll_interval, actor_id).await
}
