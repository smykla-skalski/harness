//! Explicit live validation for the OpenRouter HTTP adapter.

use futures_util::StreamExt;
use harness_openrouter_agent::openrouter::{
    ChatMessage, ChatRequest, ChatRole, OpenRouterClient,
};

const DEFAULT_BASE_URL: &str = "https://openrouter.ai/api/v1";
const DEFAULT_MODEL: &str = "deepseek/deepseek-v4-flash";

#[tokio::test]
#[ignore = "explicit live validation; requires OPENROUTER_API_KEY"]
async fn completes_streaming_turn() {
    let model = std::env::var("OPENROUTER_MODEL").unwrap_or_else(|_| DEFAULT_MODEL.to_owned());
    let api_key = required_api_key(&model);
    let base_url =
        std::env::var("OPENROUTER_API_URL").unwrap_or_else(|_| DEFAULT_BASE_URL.to_owned());
    let client = OpenRouterClient::new(base_url, api_key, "https://harness.dev", "Harness")
        .unwrap_or_else(|error| fail("client", &model, error));
    let mut stream = client
        .stream_chat(request(&model))
        .await
        .unwrap_or_else(|error| fail("request", &model, error));
    let mut response = String::new();
    let mut completed = false;

    while let Some(chunk) = stream.next().await {
        let chunk = chunk.unwrap_or_else(|error| fail("stream", &model, error));
        for choice in chunk.choices {
            if let Some(content) = choice.delta.content {
                response.push_str(&content);
            }
            completed |= choice.finish_reason.is_some();
        }
    }

    assert!(
        completed,
        "OpenRouter live validation failed: stage=result requested_model={model}: stream ended without a terminal finish reason"
    );
    assert!(
        !response.trim().is_empty(),
        "OpenRouter live validation failed: stage=result requested_model={model}: completed turn returned no assistant text"
    );
}

fn required_api_key(model: &str) -> String {
    let Ok(value) = std::env::var("OPENROUTER_API_KEY") else {
        panic!(
            "OpenRouter live validation stopped before network: stage=credential requested_model={model}: OPENROUTER_API_KEY is missing"
        );
    };
    let value = value.trim();
    assert!(
        !value.is_empty(),
        "OpenRouter live validation stopped before network: stage=credential requested_model={model}: OPENROUTER_API_KEY is empty"
    );
    value.to_owned()
}

fn request(model: &str) -> ChatRequest {
    ChatRequest {
        model: model.to_owned(),
        messages: vec![ChatMessage {
            role: ChatRole::User,
            content: Some("Reply with one short sentence confirming this adapter test.".to_owned()),
            tool_call_id: None,
            name: None,
            tool_calls: Vec::new(),
        }],
        stream: true,
        tools: Vec::new(),
        tool_choice: None,
        parallel_tool_calls: None,
        reasoning: None,
        temperature: Some(0.0),
        max_tokens: Some(64),
    }
}

fn fail(stage: &str, model: &str, error: impl std::fmt::Display) -> ! {
    panic!(
        "OpenRouter live validation failed: stage={stage} requested_model={model}: {error}"
    )
}
