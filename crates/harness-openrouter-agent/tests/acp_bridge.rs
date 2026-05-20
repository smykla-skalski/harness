//! Integration tests for the ACP bridge.
//!
//! Spawn the real `harness-openrouter-agent` binary, drive it from a parent
//! `Client`-role connection, point its `OPENROUTER_API_URL` at a wiremock
//! server, and verify the full session lifecycle:
//!
//! - `initialize` round-trips with the right agent info.
//! - `session/new` returns a session id and the curated model state.
//! - `session/prompt` streams `AgentMessageChunk` notifications and resolves
//!   with the right `StopReason`.
//! - Tool calls round-trip through the daemon-side ACP client: the model
//!   asks for `read_text_file`, the bridge sends `ReadTextFileRequest`, the
//!   test responds with file contents, and the model receives them back as
//!   a tool message before issuing the final assistant turn.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use agent_client_protocol::schema::{
    ContentBlock, CreateTerminalRequest, CreateTerminalResponse, EnvVariable, InitializeRequest,
    KillTerminalRequest, KillTerminalResponse, McpServer, McpServerStdio, NewSessionRequest,
    PromptRequest, ProtocolVersion, ReadTextFileRequest, ReadTextFileResponse,
    ReleaseTerminalRequest, ReleaseTerminalResponse, RequestPermissionRequest,
    RequestPermissionResponse, SessionNotification, SessionUpdate, StopReason, TerminalId,
    TerminalOutputRequest, TerminalOutputResponse, TextContent, WaitForTerminalExitRequest,
    WaitForTerminalExitResponse, WriteTextFileRequest, WriteTextFileResponse,
};
use agent_client_protocol::{AcpAgent, Agent, Client, ConnectionTo};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

const BIN_PATH: &str = env!("CARGO_BIN_EXE_harness-openrouter-agent");

#[derive(Debug, Default, Clone)]
struct ChunkLog {
    inner: Arc<Mutex<Vec<String>>>,
}

impl ChunkLog {
    fn push(&self, text: String) {
        self.inner.lock().expect("lock").push(text);
    }

    fn snapshot(&self) -> Vec<String> {
        self.inner.lock().expect("lock").clone()
    }
}

fn build_agent(server_url: &str) -> AcpAgent {
    let stdio = McpServerStdio::new("openrouter-shim", PathBuf::from(BIN_PATH)).env(vec![
        EnvVariable::new("OPENROUTER_API_KEY", "sk-test"),
        EnvVariable::new("OPENROUTER_API_URL", server_url.to_owned()),
        EnvVariable::new("HARNESS_OPENROUTER_LOG", "off"),
    ]);
    AcpAgent::new(McpServer::Stdio(stdio))
}

fn sse(body: &[&str]) -> String {
    let mut joined = String::new();
    for line in body {
        joined.push_str("data: ");
        joined.push_str(line);
        joined.push_str("\n\n");
    }
    joined.push_str("data: [DONE]\n\n");
    joined
}

async fn mount_models(server: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/models/user"))
        .respond_with(ResponseTemplate::new(200).set_body_string(r#"{"data":[]}"#))
        .mount(server)
        .await;
}

fn client_builder_with_chunks(
    log: ChunkLog,
) -> agent_client_protocol::Builder<
    Client,
    impl agent_client_protocol::HandleDispatchFrom<Agent>,
    agent_client_protocol::NullRun,
> {
    Client
        .builder()
        .name("test-client")
        .on_receive_notification(
            async move |notif: SessionNotification, _cx| {
                if let SessionUpdate::AgentMessageChunk(chunk) = notif.update
                    && let ContentBlock::Text(text) = chunk.content
                {
                    log.push(text.text);
                }
                Ok(())
            },
            agent_client_protocol::on_receive_notification!(),
        )
        // Tool dispatch handlers: respond with deterministic test data.
        .on_receive_request(
            async move |req: ReadTextFileRequest, responder, _cx| {
                let body = format!("read:{}", req.path.display());
                responder.respond(ReadTextFileResponse::new(body))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: WriteTextFileRequest, responder, _cx| {
                responder.respond(WriteTextFileResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: CreateTerminalRequest, responder, _cx| {
                responder.respond(CreateTerminalResponse::new(TerminalId::new(
                    "term-1".to_owned(),
                )))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: TerminalOutputRequest, responder, _cx| {
                responder.respond(TerminalOutputResponse::new("out".to_owned(), false))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: WaitForTerminalExitRequest, responder, _cx| {
                let mut resp = WaitForTerminalExitResponse::new(Default::default());
                resp.exit_status.exit_code = Some(0);
                responder.respond(resp)
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: KillTerminalRequest, responder, _cx| {
                responder.respond(KillTerminalResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: ReleaseTerminalRequest, responder, _cx| {
                responder.respond(ReleaseTerminalResponse::new())
            },
            agent_client_protocol::on_receive_request!(),
        )
        .on_receive_request(
            async move |_req: RequestPermissionRequest, responder, _cx| {
                use agent_client_protocol::schema::{RequestPermissionOutcome, SelectedPermissionOutcome};
                responder.respond(RequestPermissionResponse::new(
                    RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                        "approve".to_owned(),
                    )),
                ))
            },
            agent_client_protocol::on_receive_request!(),
        )
}

#[tokio::test]
async fn initialize_round_trips() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    let agent = build_agent(&server.uri());

    let log = ChunkLog::default();
    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            let response = cx
                .send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let info = response.agent_info.expect("agent info");
            assert_eq!(info.name, "harness-openrouter-agent");
            Ok(())
        })
        .await
        .expect("connection drives to completion");
}

#[tokio::test]
async fn session_new_returns_session_id_and_models() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    let agent = build_agent(&server.uri());
    let log = ChunkLog::default();

    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let response = cx
                .send_request(NewSessionRequest::new(PathBuf::from(
                    std::env::temp_dir(),
                )))
                .block_task()
                .await?;
            assert!(!response.session_id.0.as_ref().is_empty());
            let models = response.models.expect("models");
            assert!(!models.available_models.is_empty());
            assert_eq!(
                models.current_model_id.0.as_ref(),
                "anthropic/claude-sonnet-4-6"
            );
            Ok(())
        })
        .await
        .expect("connection drives to completion");
}

#[tokio::test]
async fn prompt_streams_text_and_returns_end_turn() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    let body = sse(&[
        r#"{"id":"gen-1","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello "}}]}"#,
        r#"{"id":"gen-1","choices":[{"index":0,"delta":{"content":"world"},"finish_reason":"stop"}]}"#,
    ]);
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(body),
        )
        .mount(&server)
        .await;
    let agent = build_agent(&server.uri());
    let log = ChunkLog::default();
    let log_for_assert = log.clone();

    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let response = cx
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new("Hi"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");

    let chunks = log_for_assert.snapshot();
    let concatenated = chunks.join("");
    assert_eq!(concatenated, "Hello world");
}

#[tokio::test]
async fn prompt_round_trips_a_tool_call() {
    let server = MockServer::start().await;
    mount_models(&server).await;

    // First completion: emit a tool_call for read_text_file (no text).
    let first = sse(&[
        r#"{"id":"gen-1","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_text_file","arguments":"{\"path\":\"hello.txt\"}"}}]},"finish_reason":"tool_calls"}]}"#,
    ]);
    // Second completion (after the tool result is fed back): emit final text.
    let second = sse(&[
        r#"{"id":"gen-2","choices":[{"index":0,"delta":{"role":"assistant","content":"file says: "}}]}"#,
        r#"{"id":"gen-2","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}"#,
    ]);
    let first_matcher = |req: &Request| -> bool {
        let body: serde_json::Value = match serde_json::from_slice(&req.body) {
            Ok(value) => value,
            Err(_) => return false,
        };
        // Tool-result message has not been appended yet.
        !body["messages"]
            .as_array()
            .map(|messages| {
                messages
                    .iter()
                    .any(|msg| msg["role"] == "tool")
            })
            .unwrap_or(false)
    };
    let second_matcher = |req: &Request| -> bool {
        let body: serde_json::Value = match serde_json::from_slice(&req.body) {
            Ok(value) => value,
            Err(_) => return false,
        };
        body["messages"]
            .as_array()
            .map(|messages| messages.iter().any(|msg| msg["role"] == "tool"))
            .unwrap_or(false)
    };
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(second_matcher)
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(second),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(first_matcher)
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(first),
        )
        .mount(&server)
        .await;

    let agent = build_agent(&server.uri());
    let log = ChunkLog::default();
    let log_for_assert = log.clone();

    client_builder_with_chunks(log)
        .connect_with(agent, |cx: ConnectionTo<Agent>| async move {
            cx.send_request(InitializeRequest::new(ProtocolVersion::LATEST))
                .block_task()
                .await?;
            let session = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let response = cx
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new("Read it"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");

    let concatenated = log_for_assert.snapshot().join("");
    assert_eq!(concatenated, "file says: hi");
}
