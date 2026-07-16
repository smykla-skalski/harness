//! Integration tests for the OpenRouter ACP bridge.

use agent_client_protocol::schema::{
    CancelNotification, ContentBlock, InitializeRequest, NewSessionRequest, PromptRequest,
    ProtocolVersion, StopReason, TextContent,
};
use agent_client_protocol::{Agent, ConnectionTo};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

use self::core::{ChunkLog, build_agent, client_builder_with_chunks, mount_models, sse};

#[path = "acp_bridge/core.rs"]
mod core;
#[path = "acp_bridge/resilience.rs"]
mod resilience;
