use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, ScreenshotOptions, screenshot};
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError};

use super::shared::decode_params;

const MAX_INLINE_SCREENSHOT_BASE64_BYTES: usize = 1_000_000;

#[derive(Debug, Deserialize)]
struct Params {
    #[serde(rename = "windowID", default)]
    window_id: Option<u32>,
    #[serde(rename = "displayID", default)]
    display_id: Option<u32>,
    #[serde(rename = "includeCursor", default)]
    include_cursor: bool,
}

pub struct ScreenshotWindowTool;

#[async_trait]
impl Tool for ScreenshotWindowTool {
    fn name(&self) -> &'static str {
        "screenshot_window"
    }

    fn description(&self) -> &'static str {
        "Capture a PNG screenshot. If windowID is provided, capture that \
         window; otherwise the display. Returns an inline image block when \
         the encoded payload stays within the safe size limit."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "windowID": {"type": "integer"},
                "displayID": {"type": "integer"},
                "includeCursor": {"type": "boolean"},
            },
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        let options = ScreenshotOptions {
            window_id: parsed.window_id,
            display_id: parsed.display_id,
            include_cursor: parsed.include_cursor,
        };
        match screenshot(&options).await {
            Ok(bytes) => Ok(screenshot_tool_result(bytes)),
            Err(error) => Err(map_automation_error(&error)),
        }
    }
}

fn screenshot_tool_result(bytes: Vec<u8>) -> ToolResult {
    let byte_len = bytes.len();
    let encoded_len = base64_encoded_len(byte_len);
    if encoded_len <= MAX_INLINE_SCREENSHOT_BASE64_BYTES {
        return ToolResult::image(bytes, "image/png");
    }
    ToolResult::text(format!(
        "Captured PNG screenshot but omitted the inline image because the \
         base64 payload would be {encoded_len} bytes, exceeding the \
         {MAX_INLINE_SCREENSHOT_BASE64_BYTES}-byte safety limit."
    ))
}

const fn base64_encoded_len(byte_len: usize) -> usize {
    byte_len.div_ceil(3) * 4
}

fn map_automation_error(error: &AutomationError) -> ToolError {
    ToolError::internal(error.to_string())
}

#[cfg(test)]
mod tests {
    use crate::mcp::protocol::ContentBlock;

    use super::{MAX_INLINE_SCREENSHOT_BASE64_BYTES, base64_encoded_len, screenshot_tool_result};

    #[test]
    fn screenshot_tool_result_keeps_small_pngs_inline() {
        let raw_len = (MAX_INLINE_SCREENSHOT_BASE64_BYTES / 4) * 3;
        let result = screenshot_tool_result(vec![0_u8; raw_len]);
        assert!(!result.is_error);
        assert_eq!(result.content.len(), 1);
        match &result.content[0] {
            ContentBlock::Image { mime_type, data } => {
                assert_eq!(mime_type, "image/png");
                assert_eq!(data.len(), MAX_INLINE_SCREENSHOT_BASE64_BYTES);
            }
            other => panic!("expected image block, got {other:?}"),
        }
    }

    #[test]
    fn screenshot_tool_result_falls_back_to_text_for_large_pngs() {
        let raw_len = ((MAX_INLINE_SCREENSHOT_BASE64_BYTES / 4) * 3) + 1;
        let result = screenshot_tool_result(vec![0_u8; raw_len]);
        assert!(!result.is_error);
        assert_eq!(result.content.len(), 1);
        match &result.content[0] {
            ContentBlock::Text { text } => {
                let encoded_len = base64_encoded_len(raw_len);
                assert!(text.contains("omitted the inline image"));
                assert!(text.contains(&encoded_len.to_string()));
            }
            other => panic!("expected text block, got {other:?}"),
        }
    }
}
