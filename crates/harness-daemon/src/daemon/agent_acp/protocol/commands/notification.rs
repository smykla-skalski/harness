use agent_client_protocol::schema::v1::{CancelNotification, SessionId};
use agent_client_protocol::{Agent, ConnectionTo, Result as AcpResult};

pub(super) fn send_cancel_notification(
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
) -> AcpResult<()> {
    connection.send_notification(CancelNotification::new(session_id))
}
