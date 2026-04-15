use std::convert::Infallible;

use async_stream::stream;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::response::sse::{Event, KeepAlive, Sse};
use tokio::sync::broadcast;

use crate::daemon::protocol::StreamEvent;
use crate::daemon::read_cache::run_canonical_db_read;
use crate::daemon::service;
use crate::errors::CliError;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::map_json;

pub(super) async fn stream_global(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Result<Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>>, Response> {
    require_auth(&headers, &state).map_err(|response| *response)?;
    let mut receiver = state.sender.subscribe();
    let initial_events = load_global_initial_events(&state)
        .await
        .map_err(|error| map_json(Err::<Vec<StreamEvent>, _>(error)))?;
    let stream = stream! {
        for event in initial_events {
            let event_name = event.event.clone();
            yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
        }
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    let event_name = event.event.clone();
                    yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::default()))
}

pub(super) async fn stream_session(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Result<Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>>, Response> {
    require_auth(&headers, &state).map_err(|response| *response)?;
    let mut receiver = state.sender.subscribe();
    let initial_events = load_session_initial_events(&state, &session_id)
        .await
        .map_err(|error| map_json(Err::<Vec<StreamEvent>, _>(error)))?;
    let stream = stream! {
        for event in initial_events {
            let event_name = event.event.clone();
            yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
        }
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    if event.session_id.as_deref().is_some_and(|current| current != session_id) {
                        continue;
                    }
                    let event_name = event.event.clone();
                    yield Ok(Event::default().event(&event_name).json_data(event).expect("serialize stream event"));
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::default()))
}

pub(super) async fn load_global_initial_events(
    state: &DaemonHttpState,
) -> Result<Vec<StreamEvent>, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return Ok(service::global_stream_initial_events_async(Some(async_db.as_ref())).await);
    }

    run_canonical_db_read(
        &state.db,
        state.db_path.clone(),
        "global stream initial events",
        |db| Ok::<_, CliError>(service::global_stream_initial_events(Some(db))),
    )
    .await
}

pub(super) async fn load_session_initial_events(
    state: &DaemonHttpState,
    session_id: &str,
) -> Result<Vec<StreamEvent>, CliError> {
    if let Some(async_db) = state.async_db.get() {
        return Ok(service::session_stream_initial_events_async(
            session_id,
            Some(async_db.as_ref()),
        )
        .await);
    }

    run_canonical_db_read(
        &state.db,
        state.db_path.clone(),
        "session stream initial events",
        {
            let session_id = session_id.to_string();
            move |db| {
                Ok::<_, CliError>(service::session_stream_initial_events(
                    &session_id,
                    Some(db),
                ))
            }
        },
    )
    .await
}
