use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::Mutex;

use agent_client_protocol::schema::SessionId;

use crate::agents::acp::client::ClientError;

pub(super) const ACP_STALE_SESSION_ID: i32 = -32091;
const ENDED_ROUTE_TOMBSTONE_LIMIT: usize = 256;

#[derive(Default)]
pub(super) struct SessionRouteGuard {
    state: Mutex<RouteState>,
}

#[derive(Default)]
struct RouteState {
    routes: BTreeMap<String, RouteTarget>,
    ended: BTreeSet<String>,
    ended_order: VecDeque<String>,
    initialized_once: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RouteTarget {
    pub acp_id: String,
    pub session_id: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum RouteRejectReason {
    Unknown,
    AlreadyEnded,
    NotInitialized,
}

impl RouteRejectReason {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown_session_id",
            Self::AlreadyEnded => "session_already_ended",
            Self::NotInitialized => "routing_not_initialized",
        }
    }
}

#[derive(Debug, Clone)]
pub(super) struct RouteError {
    pub reason: RouteRejectReason,
    pub client: ClientError,
}

impl From<RouteError> for ClientError {
    fn from(error: RouteError) -> Self {
        error.client
    }
}

impl SessionRouteGuard {
    pub(super) fn start_session(&self, acp_session_id: &SessionId, target: RouteTarget) {
        let mut state = self.state.lock().expect("session route guard lock");
        state.initialized_once = true;
        let session_id = acp_session_id.to_string();
        state.ended.remove(&session_id);
        state.ended_order.retain(|ended| ended != &session_id);
        state.routes.insert(session_id, target);
    }

    pub(super) fn stop_session(&self, session_id: &SessionId) {
        let mut state = self.state.lock().expect("session route guard lock");
        let session_id = session_id.to_string();
        if state.routes.remove(&session_id).is_some() {
            state.remember_ended(session_id);
        }
    }

    pub(super) fn stop_target(&self, target: &RouteTarget) -> Option<SessionId> {
        let mut state = self.state.lock().expect("session route guard lock");
        let session_id = state
            .routes
            .iter()
            .find_map(|(session_id, route)| (route == target).then(|| session_id.clone()))?;
        state.routes.remove(&session_id);
        state.remember_ended(session_id.clone());
        Some(SessionId::new(session_id))
    }

    pub(super) fn ensure_known(&self, incoming: &SessionId) -> Result<RouteTarget, RouteError> {
        let state = self.state.lock().expect("session route guard lock");
        if let Some(target) = state.routes.get(&incoming.to_string()) {
            return Ok(target.clone());
        }
        if state.ended.contains(&incoming.to_string()) {
            return Err(RouteError {
                reason: RouteRejectReason::AlreadyEnded,
                client: ClientError::new(
                    ACP_STALE_SESSION_ID,
                    "stale_session_id: ACP session already ended",
                ),
            });
        }
        if !state.routes.is_empty() {
            return Err(RouteError {
                reason: RouteRejectReason::Unknown,
                client: ClientError::new(
                    ACP_STALE_SESSION_ID,
                    format!("stale_session_id: stale or unknown ACP session_id '{incoming}'"),
                ),
            });
        }
        if state.initialized_once {
            return Err(RouteError {
                reason: RouteRejectReason::AlreadyEnded,
                client: ClientError::new(
                    ACP_STALE_SESSION_ID,
                    "stale_session_id: ACP session already ended",
                ),
            });
        }
        Err(RouteError {
            reason: RouteRejectReason::NotInitialized,
            client: ClientError::new(
                ACP_STALE_SESSION_ID,
                "stale_session_id: ACP session routing not initialized yet",
            ),
        })
    }
}

impl RouteState {
    fn remember_ended(&mut self, session_id: String) {
        if self.ended.insert(session_id.clone()) {
            self.ended_order.push_back(session_id);
        }
        while self.ended_order.len() > ENDED_ROUTE_TOMBSTONE_LIMIT {
            if let Some(expired) = self.ended_order.pop_front() {
                self.ended.remove(&expired);
            }
        }
    }
}
