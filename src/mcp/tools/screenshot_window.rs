use std::collections::HashSet;
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
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

#[derive(Debug, Deserialize)]
struct Params {
    #[serde(rename = "outputPath")]
    output_path: String,
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
    window_id: Option<u32>,
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
         optionally filtered to displayID. Saves PNGs to outputPath and \
         returns saved file paths."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "outputPath": {"type": "string"},
                "windowID": {"type": "integer"},
                "displayID": {"type": "integer"},
                "includeCursor": {"type": "boolean"},
            },
            "required": ["outputPath"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        let windows = self.capture_windows(parsed.window_id).await?;
        if parsed.display_id.is_none() {
            return self
                .capture_registry_windows(
                    windows,
                    parsed.include_cursor,
                    Path::new(&parsed.output_path),
                )
                .await;
        }
        let options = ScreenshotOptions {
            window_id: None,
            window_ids: windows.iter().map(|window| window.id).collect(),
            display_id: parsed.display_id,
            include_cursor: parsed.include_cursor,
        };
        match screenshot(&options).await {
            Ok(bytes) => screenshot_tool_result(
                vec![CapturedScreenshot {
                    window_id: None,
                    label: None,
                    bytes,
                }],
                Path::new(&parsed.output_path),
            ),
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
        output_path: &Path,
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
                window_id: Some(window.id),
                label: multiple.then(|| screenshot_label(&window)),
                bytes,
            });
        }
        screenshot_tool_result(captures, output_path)
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

fn screenshot_tool_result(
    captures: Vec<CapturedScreenshot>,
    output_path: &Path,
) -> Result<ToolResult, ToolError> {
    let output_dir = resolve_output_dir(output_path)?;
    let save_targets = capture_targets(&output_dir, &captures);
    let mut saved_paths = Vec::with_capacity(save_targets.len());
    for (capture, target_path) in captures.into_iter().zip(save_targets) {
        fs::write(&target_path, &capture.bytes).map_err(|error| io_write_error(&error))?;
        let full = target_path
            .canonicalize()
            .map_err(|error| io_write_error(&error))?
            .display()
            .to_string();
        saved_paths.push((capture.label, full));
    }
    let mut content = Vec::new();
    for (label, full_path) in saved_paths {
        if let Some(label) = label {
            content.push(ContentBlock::text(label));
        }
        content.push(ContentBlock::text(full_path));
    }
    Ok(ToolResult {
        content,
        is_error: false,
    })
}

fn resolve_output_dir(output_path: &Path) -> Result<PathBuf, ToolError> {
    let absolute = if output_path.is_absolute() {
        output_path.to_path_buf()
    } else {
        env::current_dir()
            .map_err(|error| io_write_error(&error))?
            .join(output_path)
    };
    fs::create_dir_all(&absolute).map_err(|error| io_write_error(&error))?;
    Ok(absolute)
}

fn capture_targets(output_dir: &Path, captures: &[CapturedScreenshot]) -> Vec<PathBuf> {
    captures
        .iter()
        .enumerate()
        .map(|(index, capture)| output_dir.join(default_screenshot_name(capture, index)))
        .collect()
}

fn io_write_error(error: &io::Error) -> ToolError {
    ToolError::internal(format!("failed to save screenshot: {error}"))
}

fn default_screenshot_name(capture: &CapturedScreenshot, index: usize) -> String {
    if let Some(window_id) = capture.window_id {
        return format!("screenshot-window-{window_id}.png");
    }
    format!("screenshot-{index}.png")
}

fn screenshot_label(window: &ScreenshotRegistryWindow) -> String {
    if window.title.trim().is_empty() {
        return format!("Window {}", window.id);
    }
    format!("Window {} ({})", window.id, window.title)
}

fn map_automation_error(error: &AutomationError) -> ToolError {
    ToolError::internal(error.to_string())
}

#[cfg(test)]
mod tests {
    use crate::mcp::registry::RegistryWindow;
    use tempfile::TempDir;

    use super::{
        CapturedScreenshot, ScreenshotRegistryWindow, default_screenshot_name,
        screenshot_registry_windows, screenshot_tool_result, shareable_registry_windows,
    };

    #[test]
    fn screenshot_tool_result_saves_pngs_to_output_directory() {
        let tmp = TempDir::new().expect("tempdir");
        let output_dir = tmp.path().join("shots");
        let result = screenshot_tool_result(
            vec![CapturedScreenshot {
                window_id: Some(41),
                label: None,
                bytes: vec![1_u8, 2_u8, 3_u8],
            }],
            &output_dir,
        )
        .expect("result");
        assert!(!result.is_error);
        assert_eq!(result.content.len(), 1);
        let saved = std::fs::read(output_dir.join("screenshot-window-41.png")).expect("saved");
        assert_eq!(saved, vec![1_u8, 2_u8, 3_u8]);
    }

    #[test]
    fn default_screenshot_name_uses_window_id() {
        let named = default_screenshot_name(
            &CapturedScreenshot {
                window_id: Some(41),
                label: None,
                bytes: vec![],
            },
            0,
        );
        assert_eq!(named, "screenshot-window-41.png");
    }

    #[test]
    fn default_screenshot_name_uses_index_when_window_missing() {
        let named = default_screenshot_name(
            &CapturedScreenshot {
                window_id: None,
                label: None,
                bytes: vec![],
            },
            7,
        );
        assert_eq!(named, "screenshot-7.png");
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
