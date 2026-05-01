use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{
    AutomationError, ScreenshotOptions, screenshot, shareable_harness_window_ids,
};
use crate::mcp::protocol::{ContentBlock, ToolResult};
use crate::mcp::registry::{ListWindowsResult, RegistryClient, RegistryRequest, RegistryWindow};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, map_registry_error};

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

pub struct ScreenshotWindowTool {
    client: Arc<RegistryClient>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ScreenshotRegistryWindow {
    id: u32,
    title: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CapturedScreenshot {
    label: Option<String>,
    bytes: Vec<u8>,
}

impl ScreenshotWindowTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }
}

#[async_trait]
impl Tool for ScreenshotWindowTool {
    fn name(&self) -> &'static str {
        "screenshot_window"
    }

    fn description(&self) -> &'static str {
        "Capture PNG screenshots for the current Harness Monitor app run. If \
         windowID is provided, capture that Harness Monitor window; otherwise \
         capture only the live registry windows for the current app run, \
         optionally filtered to displayID. Returns one inline image block per \
         PNG when the encoded payload stays within the safe size limit."
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
        let windows = self.capture_windows(parsed.window_id).await?;
        if parsed.display_id.is_none() {
            return self.capture_registry_windows(windows, parsed.include_cursor).await;
        }
        let options = ScreenshotOptions {
            window_id: None,
            window_ids: windows.iter().map(|window| window.id).collect(),
            display_id: parsed.display_id,
            include_cursor: parsed.include_cursor,
        };
        match screenshot(&options).await {
            Ok(bytes) => Ok(screenshot_tool_result(vec![CapturedScreenshot {
                label: None,
                bytes,
            }])),
            Err(error) => Err(map_automation_error(&error)),
        }
    }
}

impl ScreenshotWindowTool {
    async fn capture_windows(
        &self,
        requested_window_id: Option<u32>,
    ) -> Result<Vec<ScreenshotRegistryWindow>, ToolError> {
        if requested_window_id.is_some() {
            return self.request_registry_windows(requested_window_id).await;
        }
        let registry_windows = self.request_registry_windows(None).await?;
        let shareable_ids = shareable_harness_window_ids()
            .await
            .map_err(|error| map_automation_error(&error))?;
        shareable_registry_windows(registry_windows, shareable_ids)
    }

    async fn capture_registry_windows(
        &self,
        windows: Vec<ScreenshotRegistryWindow>,
        include_cursor: bool,
    ) -> Result<ToolResult, ToolError> {
        let multiple = windows.len() > 1;
        let mut captures = Vec::with_capacity(windows.len());
        for window in windows {
            let options = ScreenshotOptions {
                window_id: Some(window.id),
                window_ids: Vec::new(),
                display_id: None,
                include_cursor,
            };
            let bytes = screenshot(&options)
                .await
                .map_err(|error| map_automation_error(&error))?;
            captures.push(CapturedScreenshot {
                label: multiple.then(|| screenshot_label(&window)),
                bytes,
            });
        }
        Ok(screenshot_tool_result(captures))
    }

    async fn request_registry_windows(
        &self,
        requested_window_id: Option<u32>,
    ) -> Result<Vec<ScreenshotRegistryWindow>, ToolError> {
        let request = RegistryRequest::ListWindows {
            id: self.client.next_request_id(),
        };
        let result: ListWindowsResult = self
            .client
            .request(&request)
            .await
            .map_err(|error| map_registry_error(&error))?;
        screenshot_registry_windows(result.windows, requested_window_id)
    }
}

fn screenshot_registry_windows(
    windows: Vec<RegistryWindow>,
    requested_window_id: Option<u32>,
) -> Result<Vec<ScreenshotRegistryWindow>, ToolError> {
    let windows: Vec<ScreenshotRegistryWindow> = windows
        .into_iter()
        .filter_map(|window| {
            let id = u32::try_from(window.id).ok()?;
            Some(ScreenshotRegistryWindow {
                id,
                title: window.title,
            })
        })
        .collect();
    if let Some(requested_window_id) = requested_window_id {
        if let Some(window) = windows
            .into_iter()
            .find(|window| window.id == requested_window_id)
        {
            return Ok(vec![window]);
        }
        return Err(ToolError::invalid(format!(
            "windowID {requested_window_id} does not reference a live Harness Monitor window."
        )));
    }
    if windows.is_empty() {
        return Err(ToolError::internal(
            "No Harness Monitor windows are available to capture.",
        ));
    }
    Ok(windows)
}

fn shareable_registry_windows(
    registry_windows: Vec<ScreenshotRegistryWindow>,
    shareable_window_ids: Vec<u32>,
) -> Result<Vec<ScreenshotRegistryWindow>, ToolError> {
    let shareable: HashSet<u32> = shareable_window_ids.into_iter().collect();
    let windows: Vec<ScreenshotRegistryWindow> = registry_windows
        .into_iter()
        .filter(|window| shareable.contains(&window.id))
        .collect();
    if windows.is_empty() {
        return Err(ToolError::internal(
            "No live shareable Harness Monitor windows are available to capture.",
        ));
    }
    Ok(windows)
}

fn screenshot_tool_result(captures: Vec<CapturedScreenshot>) -> ToolResult {
    let mut content = Vec::new();
    for capture in captures {
        if let Some(label) = capture.label {
            content.push(ContentBlock::text(label));
        }
        let byte_len = capture.bytes.len();
        let encoded_len = base64_encoded_len(byte_len);
        if encoded_len <= MAX_INLINE_SCREENSHOT_BASE64_BYTES {
            content.push(ContentBlock::image(capture.bytes, "image/png"));
            continue;
        }
        content.push(ContentBlock::text(format!(
            "Captured PNG screenshot but omitted the inline image because the \
             base64 payload would be {encoded_len} bytes, exceeding the \
             {MAX_INLINE_SCREENSHOT_BASE64_BYTES}-byte safety limit."
        )));
    }
    ToolResult {
        content,
        is_error: false,
    }
}

fn screenshot_label(window: &ScreenshotRegistryWindow) -> String {
    if window.title.trim().is_empty() {
        return format!("Window {}", window.id);
    }
    format!("Window {} ({})", window.id, window.title)
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

    use crate::mcp::registry::RegistryWindow;

    use super::{
        CapturedScreenshot, MAX_INLINE_SCREENSHOT_BASE64_BYTES, ScreenshotRegistryWindow,
        base64_encoded_len, screenshot_registry_windows, screenshot_tool_result,
        shareable_registry_windows,
    };

    #[test]
    fn screenshot_tool_result_keeps_small_pngs_inline() {
        let raw_len = (MAX_INLINE_SCREENSHOT_BASE64_BYTES / 4) * 3;
        let result = screenshot_tool_result(vec![CapturedScreenshot {
            label: None,
            bytes: vec![0_u8; raw_len],
        }]);
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
        let result = screenshot_tool_result(vec![CapturedScreenshot {
            label: None,
            bytes: vec![0_u8; raw_len],
        }]);
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

    #[test]
    fn screenshot_tool_result_labels_multiple_pngs() {
        let raw_len = 12;
        let result = screenshot_tool_result(vec![
            CapturedScreenshot {
                label: Some("Window 41 (Dashboard)".to_string()),
                bytes: vec![0_u8; raw_len],
            },
            CapturedScreenshot {
                label: Some("Window 42 (Workspace)".to_string()),
                bytes: vec![1_u8; raw_len],
            },
        ]);
        assert!(!result.is_error);
        assert_eq!(result.content.len(), 4);
        assert_eq!(
            result.content[0],
            ContentBlock::Text {
                text: "Window 41 (Dashboard)".to_string()
            }
        );
        assert!(matches!(result.content[1], ContentBlock::Image { .. }));
        assert_eq!(
            result.content[2],
            ContentBlock::Text {
                text: "Window 42 (Workspace)".to_string()
            }
        );
        assert!(matches!(result.content[3], ContentBlock::Image { .. }));
    }

    #[test]
    fn screenshot_registry_windows_collect_registry_window_ids() {
        let windows = screenshot_registry_windows(vec![
            RegistryWindow {
                id: 41,
                title: "One".to_string(),
                role: None,
                frame: crate::mcp::registry::Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 100.0,
                    height: 100.0,
                },
                is_key: false,
                is_main: false,
            },
            RegistryWindow {
                id: 42,
                title: "Two".to_string(),
                role: None,
                frame: crate::mcp::registry::Rect {
                    x: 20.0,
                    y: 20.0,
                    width: 80.0,
                    height: 80.0,
                },
                is_key: true,
                is_main: true,
            },
        ], None)
        .expect("windows");
        assert_eq!(
            windows,
            vec![
                ScreenshotRegistryWindow {
                    id: 41,
                    title: "One".to_string()
                },
                ScreenshotRegistryWindow {
                    id: 42,
                    title: "Two".to_string()
                },
            ]
        );
    }

    #[test]
    fn screenshot_registry_windows_keep_only_requested_registry_window() {
        let windows = screenshot_registry_windows(
            vec![
                RegistryWindow {
                    id: 41,
                    title: "One".to_string(),
                    role: None,
                    frame: crate::mcp::registry::Rect {
                        x: 0.0,
                        y: 0.0,
                        width: 100.0,
                        height: 100.0,
                    },
                    is_key: false,
                    is_main: false,
                },
                RegistryWindow {
                    id: 42,
                    title: "Two".to_string(),
                    role: None,
                    frame: crate::mcp::registry::Rect {
                        x: 20.0,
                        y: 20.0,
                        width: 80.0,
                        height: 80.0,
                    },
                    is_key: true,
                    is_main: true,
                },
            ],
            Some(42),
        )
        .expect("requested window");
        assert_eq!(
            windows,
            vec![ScreenshotRegistryWindow {
                id: 42,
                title: "Two".to_string()
            }]
        );
    }

    #[test]
    fn screenshot_registry_windows_reject_non_registry_window() {
        let error =
            screenshot_registry_windows(Vec::new(), Some(42)).expect_err("missing registry window");
        assert!(error.message().contains("windowID 42"));
    }

    #[test]
    fn shareable_registry_windows_keep_live_intersection() {
        let windows = shareable_registry_windows(
            vec![
                ScreenshotRegistryWindow {
                    id: 41,
                    title: "Dashboard".to_string(),
                },
                ScreenshotRegistryWindow {
                    id: 42,
                    title: "Workspace".to_string(),
                },
            ],
            vec![42, 99],
        )
        .expect("shareable windows");
        assert_eq!(
            windows,
            vec![ScreenshotRegistryWindow {
                id: 42,
                title: "Workspace".to_string()
            }]
        );
    }

    #[test]
    fn shareable_registry_windows_reject_empty_intersection() {
        let error = shareable_registry_windows(
            vec![
                ScreenshotRegistryWindow {
                    id: 41,
                    title: "Dashboard".to_string(),
                },
                ScreenshotRegistryWindow {
                    id: 42,
                    title: "Workspace".to_string(),
                },
            ],
            vec![99],
        )
        .expect_err("empty intersection");
        assert!(error.message().contains("No live shareable Harness Monitor windows"));
    }
}
