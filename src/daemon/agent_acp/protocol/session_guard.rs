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
    expected: Option<SessionId>,
    initialized_once: bool,
}

impl SessionRouteGuard {
    pub(super) fn start_session(&self, session_id: SessionId) {
        let mut state = self.state.lock().expect("session route guard lock");
        state.initialized_once = true;
        state.expected = Some(session_id);
    }

    pub(super) fn stop_session(&self, session_id: &SessionId) {
        let mut state = self.state.lock().expect("session route guard lock");
        if state.expected.as_ref() == Some(session_id) {
            state.expected = None;
        }
    }

    pub(super) fn ensure_known(&self, incoming: &SessionId) -> ClientResult<()> {
        let state = self.state.lock().expect("session route guard lock");
        if let Some(expected) = &state.expected {
            if expected == incoming {
                return Ok(());
            }
            return Err(ClientError::new(
                ACP_STALE_SESSION_ID,
                format!(
                    "stale_session_id: stale or unknown ACP session_id '{incoming}' (expected: {expected})"
                ),
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
