//! Wiremock-backed tests for the OpenRouter HTTP client. Exercise the SSE
//! stream parser, error classifier, and `/models/user` deserializer against a
//! real local HTTP server to lock down the wire shapes.

use std::time::Duration;

use futures_util::StreamExt;
use harness_openrouter_agent::openrouter::{
    ChatMessage, ChatRequest, ChatRole, FinishReason, OpenRouterClient, OpenRouterError,
};
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn sample_request() -> ChatRequest {
    ChatRequest {
        model: "anthropic/claude-sonnet-4-6".to_owned(),
        messages: vec![ChatMessage {
            role: ChatRole::User,
            content: Some("hello".to_owned()),
            tool_call_id: None,
            name: None,
            tool_calls: Vec::new(),
        }],
        stream: true,
        tools: Vec::new(),
        tool_choice: None,
        parallel_tool_calls: None,
        reasoning: None,
        temperature: None,
        max_tokens: None,
    }
}

async fn build_client(server: &MockServer) -> OpenRouterClient {
    OpenRouterClient::new(
        server.uri(),
        "sk-test".to_owned(),
        "https://harness.dev".to_owned(),
        "Harness".to_owned(),
    )
    .expect("client builds")
}

#[tokio::test]
async fn stream_parses_text_reasoning_and_tool_calls() {
    let server = MockServer::start().await;
    let body = concat!(
        ": keep-alive\n",
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hel\"}}]}\n\n",
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"Thinking\"}}]}\n\n",
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo!\"}}]}\n\n",
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"read_text_file\",\"arguments\":\"{\\\"path\\\":\\\"x\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
        "data: [DONE]\n\n",
    );
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(header("authorization", "Bearer sk-test"))
        .and(header("HTTP-Referer", "https://harness.dev"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(body),
        )
        .mount(&server)
        .await;

    let client = build_client(&server).await;
    let mut stream = client.stream_chat(sample_request()).await.expect("stream");

    let mut text = String::new();
    let mut reasoning = String::new();
    let mut last_finish = None;
    let mut tool_name = String::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.expect("chunk");
        for choice in chunk.choices {
            if let Some(content) = choice.delta.content {
                text.push_str(&content);
            }
            if let Some(thought) = choice.delta.reasoning {
                reasoning.push_str(&thought);
            }
            for tool in choice.delta.tool_calls {
                if let Some(fun) = tool.function.and_then(|f| f.name) {
                    tool_name = fun;
                }
            }
            if let Some(finish) = choice.finish_reason {
                last_finish = Some(finish);
            }
        }
    }
    assert_eq!(text, "Hello!");
    assert_eq!(reasoning, "Thinking");
    assert_eq!(tool_name, "read_text_file");
    assert!(matches!(last_finish, Some(FinishReason::ToolCalls)));
}

#[tokio::test]
async fn rate_limit_status_maps_to_rate_limited_with_retry_after() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(
            ResponseTemplate::new(429)
                .insert_header("retry-after", "11")
                .set_body_string("slow down"),
        )
        .mount(&server)
        .await;
    let client = build_client(&server).await;
    let err = match client.stream_chat(sample_request()).await {
        Ok(_) => panic!("expected error"),
        Err(err) => err,
    };
    match err {
        OpenRouterError::RateLimited {
            retry_after: Some(d),
        } => assert_eq!(d, Duration::from_secs(11)),
        other => panic!("expected RateLimited, got {other:?}"),
    }
}

#[tokio::test]
async fn payment_required_maps_to_authentication_failed() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(402).set_body_string("credits exhausted"))
        .mount(&server)
        .await;
    let client = build_client(&server).await;
    let err = match client.stream_chat(sample_request()).await {
        Ok(_) => panic!("expected error"),
        Err(err) => err,
    };
    assert!(
        matches!(err, OpenRouterError::AuthenticationFailed { .. }),
        "got {err:?}",
    );
}

#[tokio::test]
async fn moderation_status_maps_to_moderation() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(403).set_body_string("blocked"))
        .mount(&server)
        .await;
    let client = build_client(&server).await;
    let err = match client.stream_chat(sample_request()).await {
        Ok(_) => panic!("expected error"),
        Err(err) => err,
    };
    assert!(
        matches!(err, OpenRouterError::Moderation { .. }),
        "got {err:?}"
    );
}

#[tokio::test]
async fn overload_status_maps_to_overloaded() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(503).set_body_string("busy"))
        .mount(&server)
        .await;
    let client = build_client(&server).await;
    let err = match client.stream_chat(sample_request()).await {
        Ok(_) => panic!("expected error"),
        Err(err) => err,
    };
    assert!(
        matches!(err, OpenRouterError::Overloaded { status: 503 }),
        "got {err:?}",
    );
}

#[tokio::test]
async fn list_models_deserializes_user_endpoint() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/models/user"))
        .and(header("authorization", "Bearer sk-test"))
        .respond_with(
            ResponseTemplate::new(200).set_body_string(
                r#"{"data":[{"id":"anthropic/claude-haiku-4-5","name":"Haiku"}]}"#,
            ),
        )
        .mount(&server)
        .await;
    let client = build_client(&server).await;
    let response = client.list_models().await.expect("list models");
    assert_eq!(response.data.len(), 1);
    assert_eq!(response.data[0].id, "anthropic/claude-haiku-4-5");
    assert_eq!(response.data[0].name.as_deref(), Some("Haiku"));
}

#[tokio::test]
async fn done_terminator_ends_stream_cleanly() {
    let server = MockServer::start().await;
    let body = concat!(
        "data: {\"id\":\"gen-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n",
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
    let client = build_client(&server).await;
    let mut stream = client.stream_chat(sample_request()).await.expect("stream");
    let mut chunk_count = 0;
    while let Some(chunk) = stream.next().await {
        chunk.expect("ok");
        chunk_count += 1;
    }
    assert_eq!(chunk_count, 1);
}
