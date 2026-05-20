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
    CancelNotification, ContentBlock, CreateTerminalRequest, CreateTerminalResponse, EnvVariable,
    InitializeRequest, KillTerminalRequest, KillTerminalResponse, McpServer, McpServerStdio,
    NewSessionRequest, PromptRequest, ProtocolVersion, ReadTextFileRequest, ReadTextFileResponse,
    ReleaseTerminalRequest, ReleaseTerminalResponse, RequestPermissionRequest,
    RequestPermissionResponse, SessionNotification, SessionUpdate, StopReason, TerminalId,
    TerminalOutputRequest, TerminalOutputResponse, TextContent, WaitForTerminalExitRequest,
    WaitForTerminalExitResponse, WriteTextFileRequest, WriteTextFileResponse,
};
use agent_client_protocol::{AcpAgent, Agent, Client, ConnectionTo};
use tokio::process::Command;
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
async fn probe_flag_exits_success_without_api_key() {
    // The catalog descriptor's doctor_probe runs the shim with --probe to
    // detect installation. It must exit 0 without spinning up the runtime
    // and without requiring OPENROUTER_API_KEY.
    let status = Command::new(BIN_PATH)
        .arg("--probe")
        .env_remove("OPENROUTER_API_KEY")
        .status()
        .await
        .expect("spawn shim");
    assert!(status.success(), "probe exited with {status}");
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

#[tokio::test]
async fn parallel_tool_calls_in_one_chunk_dispatch_in_index_order() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    // Two tool_calls keyed by index 0 and 1 in a single SSE delta.
    let parallel = sse(&[
        r#"{"id":"par","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"c0","type":"function","function":{"name":"read_text_file","arguments":"{\"path\":\"a\"}"}},{"index":1,"id":"c1","type":"function","function":{"name":"read_text_file","arguments":"{\"path\":\"b\"}"}}]},"finish_reason":"tool_calls"}]}"#,
    ]);
    let final_text = sse(&[
        r#"{"id":"fin","choices":[{"index":0,"delta":{"content":"done"},"finish_reason":"stop"}]}"#,
    ]);
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(|req: &Request| -> bool {
            let body: serde_json::Value = match serde_json::from_slice(&req.body) {
                Ok(value) => value,
                Err(_) => return false,
            };
            body["messages"]
                .as_array()
                .map(|msgs| msgs.iter().any(|m| m["role"] == "tool"))
                .unwrap_or(false)
        })
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(final_text),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(parallel),
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
                    vec![ContentBlock::Text(TextContent::new("Parallel"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    assert!(
        log_for_assert.snapshot().iter().any(|s| s == "done"),
        "expected final text after both tool calls resolved",
    );
}

#[tokio::test]
async fn tool_iteration_cap_returns_max_turn_requests() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    // Every chat completion returns a tool_call, so the shim loops until it
    // hits MAX_TOOL_ITERATIONS=10 and bails with MaxTurnRequests.
    let tool_call = sse(&[
        r#"{"id":"loop","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_loop","type":"function","function":{"name":"read_text_file","arguments":"{\"path\":\"x.txt\"}"}}]},"finish_reason":"tool_calls"}]}"#,
    ]);
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(tool_call),
        )
        .mount(&server)
        .await;

    let agent = build_agent(&server.uri());
    client_builder_with_chunks(ChunkLog::default())
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
                    vec![ContentBlock::Text(TextContent::new("Loop"))],
                ))
                .block_task()
                .await?;
            assert!(
                matches!(response.stop_reason, StopReason::MaxTurnRequests),
                "expected MaxTurnRequests after the iteration cap, got {:?}",
                response.stop_reason,
            );
            Ok(())
        })
        .await
        .expect("connection drives to completion");
}

#[tokio::test]
async fn http_error_surfaces_as_end_turn_with_diagnostic_chunk() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(429).insert_header("retry-after", "1"))
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
    let chunks = log_for_assert.snapshot().join("");
    assert!(
        chunks.contains("openrouter error"),
        "expected diagnostic chunk, got {chunks:?}",
    );
    assert!(
        chunks.to_lowercase().contains("rate limit"),
        "expected rate-limit phrasing, got {chunks:?}",
    );
}

#[tokio::test]
async fn moderation_status_surfaces_as_refusal() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(403).set_body_string("blocked"))
        .mount(&server)
        .await;

    let agent = build_agent(&server.uri());
    client_builder_with_chunks(ChunkLog::default())
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
                    vec![ContentBlock::Text(TextContent::new("forbidden"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(response.stop_reason, StopReason::Refusal));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
}

#[tokio::test]
async fn cancel_mid_stream_returns_cancelled_stop_reason() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    // Stream emits one chunk and then stalls. We send `session/cancel` once
    // the chunk arrives; the shim's per-session cancel flag is checked
    // between SSE chunks and aborts the turn even though the upstream stream
    // is still open.
    let body = format!(
        "{}{}{}",
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}\n\n",
        // Delay between events does not exist in wiremock; we send a second
        // event that the shim will start receiving after the cancel flag is
        // already set. The flag is polled between chunks, so the second chunk
        // is dropped on the floor and the loop short-circuits.
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"never\"}}]}\n\n",
        "data: [DONE]\n\n",
    );
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
            let session_id = session.session_id.clone();
            // Issue the prompt and cancel concurrently.
            let prompt = cx.send_request(PromptRequest::new(
                session_id.clone(),
                vec![ContentBlock::Text(TextContent::new("Stream"))],
            ));
            // Give the shim a brief moment to begin the turn, then cancel.
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            cx.send_notification(CancelNotification::new(session_id))?;
            let response = prompt.block_task().await?;
            assert!(
                matches!(
                    response.stop_reason,
                    StopReason::Cancelled | StopReason::EndTurn,
                ),
                "expected Cancelled or EndTurn, got {:?}",
                response.stop_reason,
            );
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    let _ = log_for_assert.snapshot();
}

#[tokio::test]
async fn multiple_sessions_keep_isolated_histories() {
    let server = MockServer::start().await;
    mount_models(&server).await;
    // Match the body content to differentiate the two prompts.
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(|req: &Request| -> bool {
            let body: serde_json::Value = match serde_json::from_slice(&req.body) {
                Ok(value) => value,
                Err(_) => return false,
            };
            body["messages"][0]["content"] == "first"
        })
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse(&[
                    r#"{"id":"a","choices":[{"index":0,"delta":{"content":"one"},"finish_reason":"stop"}]}"#,
                ])),
        )
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(|req: &Request| -> bool {
            let body: serde_json::Value = match serde_json::from_slice(&req.body) {
                Ok(value) => value,
                Err(_) => return false,
            };
            body["messages"][0]["content"] == "second"
        })
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(sse(&[
                    r#"{"id":"b","choices":[{"index":0,"delta":{"content":"two"},"finish_reason":"stop"}]}"#,
                ])),
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
            let session_a = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            let session_b = cx
                .send_request(NewSessionRequest::new(std::env::temp_dir()))
                .block_task()
                .await?;
            assert_ne!(session_a.session_id.0, session_b.session_id.0);
            let r_a = cx
                .send_request(PromptRequest::new(
                    session_a.session_id,
                    vec![ContentBlock::Text(TextContent::new("first"))],
                ))
                .block_task()
                .await?;
            let r_b = cx
                .send_request(PromptRequest::new(
                    session_b.session_id,
                    vec![ContentBlock::Text(TextContent::new("second"))],
                ))
                .block_task()
                .await?;
            assert!(matches!(r_a.stop_reason, StopReason::EndTurn));
            assert!(matches!(r_b.stop_reason, StopReason::EndTurn));
            Ok(())
        })
        .await
        .expect("connection drives to completion");
    let chunks = log_for_assert.snapshot();
    assert!(chunks.iter().any(|s| s == "one"), "got {chunks:?}");
    assert!(chunks.iter().any(|s| s == "two"), "got {chunks:?}");
}
