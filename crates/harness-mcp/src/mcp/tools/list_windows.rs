use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{ListWindowsResult, RegistryClient, RegistryRequest};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{map_registry_error, ok_text};

pub struct ListWindowsTool {
    client: Arc<RegistryClient>,
}

impl ListWindowsTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }
}

#[async_trait]
impl Tool for ListWindowsTool {
    fn name(&self) -> &'static str {
        "list_windows"
    }

    fn description(&self) -> &'static str {
        "List Harness Monitor windows with their CGWindowID, title, role, \
         and frame in global screen coordinates."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {},
            "additionalProperties": false,
        })
    }

    async fn call(&self, _params: Value) -> Result<ToolResult, ToolError> {
        let id = self.client.next_request_id();
        let request = RegistryRequest::ListWindows { id };
        let result: ListWindowsResult = self
            .client
            .request(&request)
            .await
            .map_err(|error| map_registry_error(&error))?;
        ok_text(&result)
    }
}
