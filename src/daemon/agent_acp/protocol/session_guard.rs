use std::sync::Mutex;

use agent_client_protocol::schema::SessionId;

use crate::agents::acp::client::{ClientError, ClientResult};

pub(super) const ACP_STALE_SESSION_ID: i32 = -32091;

#[derive(Default)]
pub(super) struct SessionRouteGuard {
    expected: Mutex<Option<SessionId>>,
}

impl SessionRouteGuard {
    pub(super) fn set_expected(&self, session_id: SessionId) {
        *self.expected.lock().expect("session route guard lock") = Some(session_id);
    }

    pub(super) fn ensure_known(&self, incoming: &SessionId) -> ClientResult<()> {
        let expected = self
            .expected
            .lock()
            .expect("session route guard lock")
            .clone();
        if let Some(session_id) = expected.clone()
            && &session_id == incoming
        {
            return Ok(());
        }
        if let Some(expected) = expected {
            return Err(ClientError::new(
                ACP_STALE_SESSION_ID,
                format!(
                    "stale or unknown ACP session_id '{incoming}' (expected '{expected}')"
                ),
            ));
        }
        Err(ClientError::new(
                ACP_STALE_SESSION_ID,
                "ACP session routing not initialized yet",
            ))
    }
}
