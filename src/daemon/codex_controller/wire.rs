use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

use super::approvals::trim_summary;

pub(super) const METHOD_INITIALIZE: &str = "initialize";
pub(super) const METHOD_INITIALIZED: &str = "initialized";
pub(super) const METHOD_THREAD_START: &str = "thread/start";
pub(super) const METHOD_THREAD_RESUME: &str = "thread/resume";
pub(super) const METHOD_TURN_START: &str = "turn/start";
pub(super) const METHOD_TURN_STEER: &str = "turn/steer";
pub(super) const METHOD_TURN_INTERRUPT: &str = "turn/interrupt";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum AppServerNotification {
    TurnStarted {
        turn_id: Option<String>,
    },
    AgentMessageDelta {
        delta: Option<String>,
    },
    ItemCompleted {
        item: CompletedItem,
    },
    TurnCompleted {
        status: Option<String>,
        error_message: Option<String>,
    },
    Error {
        message: Option<String>,
    },
    Other,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct CompletedItem {
    pub(super) kind: Option<String>,
    pub(super) text: Option<String>,
    pub(super) phase: Option<String>,
}

pub(super) fn initialize_params(version: &str) -> Result<Value, CliError> {
    to_value(
        "codex initialize params",
        &InitializeParams {
            client_info: ClientInfo {
                name: "harness-daemon",
                title: "Harness daemon",
                version,
            },
            capabilities: InitializeCapabilities {
                experimental_api: true,
            },
        },
    )
}

#[derive(Clone, Copy)]
pub(super) struct ThreadParamsInput<'a> {
    pub(super) cwd: &'a str,
    pub(super) sandbox: &'a str,
    pub(super) approval_policy: &'a str,
    pub(super) developer_instructions: &'a str,
    pub(super) thread_id: Option<&'a str>,
    pub(super) model: Option<&'a str>,
    pub(super) effort: Option<&'a str>,
}

pub(super) fn thread_params(input: ThreadParamsInput<'_>) -> Result<Value, CliError> {
    to_value(
        "codex thread params",
        &ThreadParams {
            cwd: input.cwd,
            sandbox: input.sandbox,
            approval_policy: input.approval_policy,
            approvals_reviewer: "user",
            persist_extended_history: true,
            developer_instructions: input.developer_instructions,
            thread_id: input.thread_id,
            model: input.model,
            reasoning: input.effort.map(|effort| ReasoningParams { effort }),
        },
    )
}

pub(super) fn turn_start_params(
    thread_id: &str,
    cwd: &str,
    prompt: &str,
    approval_policy: &str,
    sandbox_policy: Value,
) -> Result<Value, CliError> {
    to_value(
        "codex turn start params",
        &TurnStartParams {
            thread_id,
            cwd,
            input: vec![InputItem::Text { text: prompt }],
            approval_policy,
            approvals_reviewer: "user",
            sandbox_policy,
        },
    )
}

pub(super) fn turn_steer_params(
    thread_id: &str,
    turn_id: &str,
    prompt: &str,
) -> Result<Value, CliError> {
    to_value(
        "codex turn steer params",
        &TurnSteerParams {
            thread_id,
            expected_turn_id: turn_id,
            input: vec![InputItem::Text { text: prompt }],
        },
    )
}

pub(super) fn turn_interrupt_params(thread_id: &str, turn_id: &str) -> Result<Value, CliError> {
    to_value(
        "codex turn interrupt params",
        &TurnInterruptParams { thread_id, turn_id },
    )
}

pub(super) fn thread_id_from_result(result: &Value) -> Option<String> {
    serde_json::from_value::<ThreadResult>(result.clone())
        .ok()
        .map(|result| result.thread.id)
}

pub(super) fn turn_id_from_result(result: &Value) -> Option<String> {
    serde_json::from_value::<TurnResult>(result.clone())
        .ok()
        .map(|result| result.turn.id)
}

pub(super) fn parse_notification(method: &str, params: &Value) -> AppServerNotification {
    match method {
        "turn/started" => AppServerNotification::TurnStarted {
            turn_id: parse::<TurnResult>(params).map(|params| params.turn.id),
        },
        "item/agentMessage/delta" => AppServerNotification::AgentMessageDelta {
            delta: parse::<AgentMessageDeltaParams>(params).and_then(|params| params.delta),
        },
        "item/completed" => AppServerNotification::ItemCompleted {
            item: parse::<ItemCompletedParams>(params)
                .map(|params| CompletedItem {
                    kind: params.item.kind,
                    text: params.item.text,
                    phase: params.item.phase,
                })
                .unwrap_or_default(),
        },
        "turn/completed" => {
            let parsed = parse::<TurnCompletedParams>(params);
            AppServerNotification::TurnCompleted {
                status: parsed
                    .as_ref()
                    .and_then(|params| params.turn.status.clone()),
                error_message: parsed
                    .and_then(|params| params.turn.error)
                    .and_then(|error| error.message),
            }
        }
        "error" => AppServerNotification::Error {
            message: parse::<ErrorParams>(params).and_then(|params| params.message),
        },
        _ => AppServerNotification::Other,
    }
}

pub(super) fn notification_summary(method: &str, params: &Value) -> String {
    if method == "item/agentMessage/delta" {
        return params
            .get("delta")
            .and_then(Value::as_str)
            .map_or_else(|| "Agent message delta".to_string(), trim_summary);
    }
    if let Some(item_type) = params.pointer("/item/type").and_then(Value::as_str) {
        return format!("{method}: {item_type}");
    }
    if let Some(status) = params.pointer("/turn/status").and_then(Value::as_str) {
        return format!("{method}: {status}");
    }
    method.to_string()
}

pub(super) fn value_id_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        _ => value.to_string(),
    }
}

fn to_value<T: Serialize>(label: &str, value: &T) -> Result<Value, CliError> {
    serde_json::to_value(value)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("{label}: {error}")).into())
}

fn parse<T: for<'de> Deserialize<'de>>(value: &Value) -> Option<T> {
    serde_json::from_value(value.clone()).ok()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InitializeParams<'a> {
    client_info: ClientInfo<'a>,
    capabilities: InitializeCapabilities,
}

#[derive(Serialize)]
struct ClientInfo<'a> {
    name: &'a str,
    title: &'a str,
    version: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InitializeCapabilities {
    experimental_api: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadParams<'a> {
    cwd: &'a str,
    sandbox: &'a str,
    approval_policy: &'a str,
    approvals_reviewer: &'a str,
    persist_extended_history: bool,
    developer_instructions: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    thread_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning: Option<ReasoningParams<'a>>,
}

#[derive(Serialize)]
struct ReasoningParams<'a> {
    effort: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnStartParams<'a> {
    thread_id: &'a str,
    cwd: &'a str,
    input: Vec<InputItem<'a>>,
    approval_policy: &'a str,
    approvals_reviewer: &'a str,
    sandbox_policy: Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnSteerParams<'a> {
    thread_id: &'a str,
    expected_turn_id: &'a str,
    input: Vec<InputItem<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnInterruptParams<'a> {
    thread_id: &'a str,
    turn_id: &'a str,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum InputItem<'a> {
    Text { text: &'a str },
}

#[derive(Deserialize)]
struct ThreadResult {
    thread: IdRef,
}

#[derive(Deserialize)]
struct TurnResult {
    turn: IdRef,
}

#[derive(Deserialize)]
struct IdRef {
    id: String,
}

#[derive(Deserialize)]
struct AgentMessageDeltaParams {
    delta: Option<String>,
}

#[derive(Deserialize)]
struct ItemCompletedParams {
    item: CompletedItemPayload,
}

#[derive(Deserialize)]
struct CompletedItemPayload {
    #[serde(rename = "type")]
    kind: Option<String>,
    text: Option<String>,
    phase: Option<String>,
}

#[derive(Deserialize)]
struct TurnCompletedParams {
    turn: TurnCompletedPayload,
}

#[derive(Deserialize)]
struct TurnCompletedPayload {
    status: Option<String>,
    error: Option<ErrorParams>,
}

#[derive(Deserialize)]
struct ErrorParams {
    message: Option<String>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        AppServerNotification, CompletedItem, ThreadParamsInput, initialize_params,
        parse_notification, thread_id_from_result, thread_params, turn_start_params,
    };

    #[test]
    fn thread_params_serialize_harness_owned_app_server_shape() {
        let value = thread_params(ThreadParamsInput {
            cwd: "/tmp/project",
            sandbox: "read-only",
            approval_policy: "on-request",
            developer_instructions: "follow harness mode",
            thread_id: Some("thread-1"),
            model: Some("gpt-5.5"),
            effort: Some("high"),
        })
        .expect("thread params serialize");

        assert_eq!(
            value,
            json!({
                "cwd": "/tmp/project",
                "sandbox": "read-only",
                "approvalPolicy": "on-request",
                "approvalsReviewer": "user",
                "persistExtendedHistory": true,
                "developerInstructions": "follow harness mode",
                "threadId": "thread-1",
                "model": "gpt-5.5",
                "reasoning": { "effort": "high" },
            })
        );
    }

    #[test]
    fn turn_start_params_serialize_text_input_and_sandbox_policy() {
        let value = turn_start_params(
            "thread-1",
            "/tmp/project",
            "hello",
            "never",
            json!({ "type": "readOnly" }),
        )
        .expect("turn params serialize");

        assert_eq!(
            value,
            json!({
                "threadId": "thread-1",
                "cwd": "/tmp/project",
                "input": [{ "type": "text", "text": "hello" }],
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "sandboxPolicy": { "type": "readOnly" },
            })
        );
    }

    #[test]
    fn notification_parser_extracts_handled_shapes_tolerantly() {
        assert_eq!(
            parse_notification("turn/started", &json!({ "turn": { "id": "turn-1" } })),
            AppServerNotification::TurnStarted {
                turn_id: Some("turn-1".to_string())
            }
        );
        assert_eq!(
            parse_notification(
                "item/completed",
                &json!({
                    "item": {
                        "type": "agentMessage",
                        "text": "done",
                        "phase": "final_answer"
                    }
                })
            ),
            AppServerNotification::ItemCompleted {
                item: CompletedItem {
                    kind: Some("agentMessage".to_string()),
                    text: Some("done".to_string()),
                    phase: Some("final_answer".to_string()),
                }
            }
        );
        assert_eq!(
            parse_notification("turn/completed", &json!({ "turn": { "status": "failed" } })),
            AppServerNotification::TurnCompleted {
                status: Some("failed".to_string()),
                error_message: None,
            }
        );
    }

    #[test]
    fn result_parsers_extract_ids_from_app_server_responses() {
        assert_eq!(
            thread_id_from_result(&json!({ "thread": { "id": "thread-1" } })),
            Some("thread-1".to_string())
        );
    }

    #[test]
    fn initialize_params_enable_experimental_api() {
        let value = initialize_params("34.1.0").expect("initialize params serialize");
        assert_eq!(
            value,
            json!({
                "clientInfo": {
                    "name": "harness-daemon",
                    "title": "Harness daemon",
                    "version": "34.1.0"
                },
                "capabilities": { "experimentalApi": true }
            })
        );
    }
}
