use super::*;

/// Start or refresh the daemon-owned session observation loop.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or observe fails.
pub fn observe_session(
    session_id: &str,
    request: Option<&ObserveSessionRequest>,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    let actor_id = request
        .and_then(|request| request.actor.as_deref())
        .filter(|value| !value.trim().is_empty());

    // Resolve project_dir from the DB when available, falling back to
    // file-based discovery.
    let project_dir = if let Some(db) = db
        && let Some(dir) = db.project_dir_for_session(session_id)?
    {
        PathBuf::from(dir)
    } else {
        let resolved = index::resolve_session(session_id)?;
        effective_project_dir(&resolved).to_path_buf()
    };

    let _ = session_observe::run_session_observe(session_id, &project_dir, actor_id)?;
    let _ = start_daemon_observe_loop(session_id, &project_dir, actor_id);
    sync_after_mutation(db, session_id);
    session_detail(session_id, db)
}

/// Build a `ready` stream event for SSE subscribers.
///
/// # Panics
/// Panics if the trivial `ReadyEventPayload` cannot be serialized to JSON.
pub fn ready_event(session_id: Option<&str>) -> StreamEvent {
    StreamEvent {
        event: "ready".to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serde_json::to_value(ReadyEventPayload { ok: true })
            .expect("serialize daemon ready payload"),
    }
}

/// Build the events every global stream subscriber receives immediately.
///
/// This closes the subscription gap between the monitor's last explicit
/// refresh and the moment the daemon marks the stream as subscribed.
#[must_use]
pub fn global_stream_initial_events(db: Option<&super::db::DaemonDb>) -> Vec<StreamEvent> {
    let mut events = vec![ready_event(None)];
    if let Ok(event) = sessions_updated_event(db) {
        events.push(event);
    }
    events
}

/// Build the events every per-session stream subscriber receives immediately.
///
/// This gives reconnecting clients a fresh selected-session snapshot even when
/// the mutation broadcast happened before the stream subscription became live.
#[must_use]
pub fn session_stream_initial_events(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Vec<StreamEvent> {
    let mut events = vec![ready_event(Some(session_id))];
    if let Ok(event) = session_updated_core_event(session_id, db) {
        events.push(event);
    }
    if let Ok(event) = session_extensions_event(session_id, db) {
        events.push(event);
    }
    events
}

/// Build a `sessions_updated` stream event with current project and session lists.
///
/// # Errors
/// Returns `CliError` when project or session discovery fails.
pub fn sessions_updated_event(db: Option<&super::db::DaemonDb>) -> Result<StreamEvent, CliError> {
    let payload = SessionsUpdatedPayload {
        projects: list_projects(db)?,
        sessions: list_sessions(true, db)?,
    };
    stream_event("sessions_updated", None, payload)
}

/// Build a `session_updated` stream event with live session detail only.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or serialized.
pub fn session_updated_event(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<StreamEvent, CliError> {
    let payload = SessionUpdatedPayload {
        detail: session_detail(session_id, db)?,
        timeline: None,
        extensions_pending: false,
    };
    stream_event("session_updated", Some(session_id), payload)
}

/// Build a lightweight `session_updated` stream event using core-only detail.
///
/// Signals, observer, and agent activity are omitted. The `extensions_pending`
/// flag tells the client that a follow-up `session_extensions` event will arrive.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or serialized.
pub fn session_updated_core_event(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<StreamEvent, CliError> {
    let payload = SessionUpdatedPayload {
        detail: session_detail_core(session_id, db)?,
        timeline: None,
        extensions_pending: true,
    };
    stream_event("session_updated", Some(session_id), payload)
}

/// Build a `session_extensions` stream event with the expensive detail fields.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or extensions fail to load.
pub fn session_extensions_event(
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) -> Result<StreamEvent, CliError> {
    let payload = session_extensions(session_id, db)?;
    stream_event("session_extensions", Some(session_id), payload)
}

pub fn broadcast_sessions_updated(
    sender: &broadcast::Sender<StreamEvent>,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(sender, sessions_updated_event(db), "sessions_updated", None);
}

pub fn broadcast_session_updated(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(
        sender,
        session_updated_event(session_id, db),
        "session_updated",
        Some(session_id),
    );
}

/// Broadcast a lightweight session update with core-only detail.
///
/// The `extensions_pending` flag tells clients that a follow-up
/// `session_extensions` event will arrive with signals, observer, and activity.
pub fn broadcast_session_updated_core(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(
        sender,
        session_updated_core_event(session_id, db),
        "session_updated",
        Some(session_id),
    );
}

/// Broadcast the expensive session detail extensions.
pub fn broadcast_session_extensions(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_event(
        sender,
        session_extensions_event(session_id, db),
        "session_extensions",
        Some(session_id),
    );
}

pub fn broadcast_session_snapshot(
    sender: &broadcast::Sender<StreamEvent>,
    session_id: &str,
    db: Option<&super::db::DaemonDb>,
) {
    broadcast_sessions_updated(sender, db);
    broadcast_session_updated_core(sender, session_id, db);
    broadcast_session_extensions(sender, session_id, db);
}

pub(crate) fn stream_event<T: Serialize>(
    event: &str,
    session_id: Option<&str>,
    payload: T,
) -> Result<StreamEvent, CliError> {
    Ok(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id: session_id.map(ToString::to_string),
        payload: serialize_event_payload(payload, event)?,
    })
}

pub(crate) fn serialize_event_payload<T: Serialize>(
    payload: T,
    event: &str,
) -> Result<Value, CliError> {
    serde_json::to_value(payload).map_err(|error| {
        CliErrorKind::workflow_io(format!("serialize daemon push '{event}': {error}")).into()
    })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn broadcast_event(
    sender: &broadcast::Sender<StreamEvent>,
    event: Result<StreamEvent, CliError>,
    event_name: &str,
    session_id: Option<&str>,
) {
    match event {
        Ok(payload) => {
            let receiver_count = sender.receiver_count();
            let _ = sender.send(payload);
            tracing::debug!(
                event = event_name,
                session_id = session_id.unwrap_or("-"),
                receiver_count,
                "broadcast event sent"
            );
        }
        Err(error) => {
            warn_broadcast_failure(&error.to_string(), event_name, session_id.unwrap_or("-"));
        }
    }
}

/// Emit a warning for a failed broadcast event.
///
/// Uses `tracing::Event::dispatch` directly because the `tracing::warn!`
/// macro expansion generates cognitive complexity 8 in clippy's analysis,
/// which exceeds the pedantic threshold of 7. See tokio-rs/tracing#553.
pub(crate) fn warn_broadcast_failure(error_message: &str, event_name: &str, session: &str) {
    use tracing::callsite::DefaultCallsite;
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata, callsite::Identifier};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "warn",
        "harness::daemon::service",
        Level::WARN,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let message = format!(
        "failed to build daemon push event '{event_name}': {error_message} (session={session})"
    );
    let values: &[Option<&dyn Value>] = &[Some(&message.as_str())];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}
