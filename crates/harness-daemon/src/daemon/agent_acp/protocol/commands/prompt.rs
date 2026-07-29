use std::time::Duration;

use agent_client_protocol::schema::v1::{ContentBlock, PromptRequest, SessionId, TextContent};
use agent_client_protocol::{Agent, ConnectionTo, Result as AcpResult};
use tokio::time::timeout;

use crate::agents::acp::supervision::AcpSessionSupervisor;

pub(super) async fn send_prompt(
    supervisor: &AcpSessionSupervisor,
    connection: &ConnectionTo<Agent>,
    session_id: SessionId,
    prompt_timeout: Duration,
    prompt: String,
) -> AcpResult<()> {
    let _guard = supervisor.enter_pending_request_with_reason(Some("session/prompt"));
    super::super::session_state::begin_turn(supervisor);
    let request = PromptRequest::new(
        session_id,
        vec![ContentBlock::Text(TextContent::new(prompt))],
    );
    let response = timeout(
        prompt_timeout,
        connection.send_request(request).block_task(),
    )
    .await
    .map_err(|_| super::super::deadline_error("session/prompt", prompt_timeout))
    .and_then(std::convert::identity);
    if let Ok(response) = &response {
        super::super::session_state::record_stop_reason(supervisor, response);
    } else {
        super::super::session_state::discard_turn(supervisor);
    }
    response.map(drop)
}
