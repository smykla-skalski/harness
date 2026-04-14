use std::collections::VecDeque;

use serde_json::{Value, json};

use crate::daemon::codex_transport::CodexTransport;
use crate::errors::{CliError, CliErrorKind};

pub(super) struct CodexJsonRpc {
    transport: Box<dyn CodexTransport>,
    pending_messages: VecDeque<Value>,
    next_id: i64,
}

impl CodexJsonRpc {
    pub(super) fn new(transport: Box<dyn CodexTransport>) -> Self {
        Self {
            transport,
            pending_messages: VecDeque::new(),
            next_id: 1,
        }
    }

    pub(super) async fn request(&mut self, method: &str, params: Value) -> Result<Value, CliError> {
        let id = self.send_request(method, params).await?;
        loop {
            let Some(message) = self.read_stdout_message().await? else {
                return Err(
                    CliErrorKind::workflow_io("codex app-server exited during request").into(),
                );
            };
            if message.get("id") != Some(&id) {
                self.pending_messages.push_back(message);
                continue;
            }
            if let Some(error) = message.get("error") {
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("codex app-server request failed");
                return Err(CliErrorKind::workflow_io(message.to_string()).into());
            }
            return Ok(message.get("result").cloned().unwrap_or(Value::Null));
        }
    }

    pub(super) async fn send_request(
        &mut self,
        method: &str,
        params: Value,
    ) -> Result<Value, CliError> {
        let id = Value::from(self.next_id);
        self.next_id += 1;
        self.send(json!({
            "id": id,
            "method": method,
            "params": params,
        }))
        .await?;
        Ok(id)
    }

    pub(super) async fn send_response(
        &mut self,
        request_id: Value,
        result: Value,
    ) -> Result<(), CliError> {
        self.send(json!({
            "id": request_id,
            "result": result,
        }))
        .await
    }

    pub(super) async fn next_message(&mut self) -> Result<Option<Value>, CliError> {
        if let Some(message) = self.pending_messages.pop_front() {
            return Ok(Some(message));
        }
        self.read_stdout_message().await
    }

    async fn send(&mut self, message: Value) -> Result<(), CliError> {
        let encoded = serde_json::to_string(&message).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("codex rpc request: {error}"))
        })?;
        self.transport.send(encoded).await
    }

    async fn read_stdout_message(&mut self) -> Result<Option<Value>, CliError> {
        let Some(line) = self.transport.next_frame().await? else {
            return Ok(None);
        };
        serde_json::from_str(&line).map(Some).map_err(|error| {
            CliErrorKind::workflow_parse(format!("parse codex app-server JSON: {error}")).into()
        })
    }
}
