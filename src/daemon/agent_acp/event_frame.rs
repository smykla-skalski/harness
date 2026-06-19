use serde::{Deserialize, Serialize};

use crate::agents::runtime::event::ConversationEvent;
use crate::session::types::ManagedAgentKind;

/// Wire frame for the `acp_events` broadcast push: a flushed batch of ACP
/// conversation events tagged with the managed-agent identity envelope.
///
/// The daemon-side producer ([`super::active::spawn_event_forwarder`]) serializes
/// this directly so the frame is statically typed at the source, and the
/// generated Swift `AcpEventBatchPayloadWire` mirrors it for the Monitor decode.
/// `managed_agent_family` is always [`ManagedAgentKind::Acp`]; the consumer
/// rejects any other family.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct AcpEventBatchPayload {
    pub managed_agent_id: String,
    pub managed_agent_family: ManagedAgentKind,
    pub session_id: String,
    pub raw_count: usize,
    pub events: Vec<ConversationEvent>,
}
