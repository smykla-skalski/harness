use std::convert::Infallible;

use async_stream::stream;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use axum::response::sse::{Event, KeepAlive, Sse};
use tokio::sync::broadcast;

use crate::daemon::service;

use super::DaemonHttpState;
use super::auth::require_auth;

pub(super) async fn stream_global(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Result<Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>>, Response> {
    require_auth(&headers, &state).map_err(|response| *response)?;
    let mut receiver = state.sender.subscribe();
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let initial_events = service::global_stream_initial_events(db_guard.as_deref());
    drop(db_guard);
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
    let db_guard = state.db.get().map(|db| db.lock().expect("db lock"));
    let initial_events = service::session_stream_initial_events(&session_id, db_guard.as_deref());
    drop(db_guard);
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
