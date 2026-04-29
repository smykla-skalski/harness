use std::collections::BTreeMap;
use std::sync::Mutex;

use agent_client_protocol::schema::SessionId;

use crate::agents::acp::client::{ClientError, ClientResult};

pub(super) const ACP_STALE_SESSION_ID: i32 = -32091;

#[derive(Default)]
pub(super) struct SessionRouteGuard {
    state: Mutex<RouteState>,
}

#[derive(Default)]
struct RouteState {
    routes: BTreeMap<String, RouteTarget>,
    initialized_once: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RouteTarget {
    pub acp_id: String,
    pub session_id: String,
}

impl SessionRouteGuard {
    pub(super) fn start_session(&self, acp_session_id: &SessionId, target: RouteTarget) {
        let mut state = self.state.lock().expect("session route guard lock");
        state.initialized_once = true;
        state.routes.insert(acp_session_id.to_string(), target);
    }

    pub(super) fn stop_session(&self, session_id: &SessionId) {
        let mut state = self.state.lock().expect("session route guard lock");
        state.routes.remove(&session_id.to_string());
    }

    pub(super) fn ensure_known(&self, incoming: &SessionId) -> ClientResult<RouteTarget> {
        let state = self.state.lock().expect("session route guard lock");
        if let Some(target) = state.routes.get(&incoming.to_string()) {
            return Ok(target.clone());
        }
        if !state.routes.is_empty() {
            return Err(ClientError::new(
                ACP_STALE_SESSION_ID,
                format!("stale_session_id: stale or unknown ACP session_id '{incoming}'"),
            ));
        }
        if state.initialized_once {
            return Err(ClientError::new(
                ACP_STALE_SESSION_ID,
                "stale_session_id: ACP session already ended",
            ));
        }
        Err(ClientError::new(
            ACP_STALE_SESSION_ID,
            "stale_session_id: ACP session routing not initialized yet",
        ))
    }
}
