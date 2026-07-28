use std::{ffi::OsString, process::Output, str, time::Duration};

use super::backend::{Backend, detect_backend};
use super::error::AutomationError;
use serde::Deserialize;
use tokio::process::Command;
use tokio::time::timeout;

const SCREENSHOT_CAPTURE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Deserialize)]
struct ShareableWindowList {
    #[serde(rename = "windowIDs")]
    window_ids: Vec<u32>,
}

#[derive(Debug, Clone, Default)]
pub struct ScreenshotOptions {
    pub window_id: Option<u32>,
    pub window_ids: Vec<u32>,
    pub display_id: Option<u32>,
    pub include_cursor: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenshotTarget {
    MainDisplay,
    Display(u32),
    Window(u32),
}

impl ScreenshotOptions {
    #[must_use]
    pub const fn target(&self) -> ScreenshotTarget {
        if let Some(window_id) = self.window_id {
            ScreenshotTarget::Window(window_id)
        } else if let Some(display_id) = self.display_id {
            ScreenshotTarget::Display(display_id)
        } else {
            ScreenshotTarget::MainDisplay
        }
    }
}

/// Capture a PNG screenshot for the selected target.
///
/// # Errors
///
/// Returns an error when the bundled native helper is unavailable, when it
/// cannot capture the requested target, or when Screen Recording permission is
/// missing.
pub async fn screenshot(options: &ScreenshotOptions) -> Result<Vec<u8>, AutomationError> {
    let backend = detect_backend().await;
    let Some((program, args)) = screenshot_args(&backend, options) else {
        return Err(AutomationError::ScreenshotBackendMissing);
    };
    run_screenshot_command(&program, &args).await
}

/// Return the currently shareable Harness Monitor window ids that the bundled
/// helper can resolve through `ScreenCaptureKit`.
///
/// # Errors
///
/// Returns an error when the helper is unavailable, Screen Recording
/// permission is missing, or the helper returns malformed output.
pub async fn shareable_harness_window_ids() -> Result<Vec<u32>, AutomationError> {
    let helper_path = harness_input_path().await?;
    let output =
        run_json_helper_command(&helper_path, &[OsString::from("list-shareable-windows")]).await?;
    parse_shareable_window_ids(&output)
}

#[must_use]
pub fn screenshot_args(
    backend: &Backend,
    options: &ScreenshotOptions,
) -> Option<(OsString, Vec<OsString>)> {
    match backend {
        Backend::HarnessInput(path) => Some((path.as_os_str().to_owned(), helper_args(options))),
        Backend::Cliclick | Backend::None => None,
    }
}

fn helper_args(options: &ScreenshotOptions) -> Vec<OsString> {
    let mut args = vec![OsString::from("screenshot")];
    if options.window_ids.is_empty() {
        match options.target() {
            ScreenshotTarget::Window(window_id) => {
                args.push(OsString::from("--window-id"));
                args.push(OsString::from(window_id.to_string()));
            }
            ScreenshotTarget::Display(display_id) => {
                args.push(OsString::from("--display-id"));
                args.push(OsString::from(display_id.to_string()));
            }
            ScreenshotTarget::MainDisplay => {}
        }
    } else {
        for window_id in &options.window_ids {
            args.push(OsString::from("--window-id"));
            args.push(OsString::from(window_id.to_string()));
        }
        if let Some(display_id) = options.display_id {
            args.push(OsString::from("--display-id"));
            args.push(OsString::from(display_id.to_string()));
        }
    }
    if options.include_cursor {
        args.push(OsString::from("--include-cursor"));
    }
    args
}

async fn run_screenshot_command(
    program: &OsString,
    args: &[OsString],
) -> Result<Vec<u8>, AutomationError> {
    let output = run_helper_command(program, args).await?;
    if output.status.success() {
        if output.stdout.is_empty() {
            return Err(AutomationError::ScreenshotCaptureFailed {
                detail: "helper returned an empty PNG payload".to_string(),
            });
        }
        return Ok(output.stdout);
    }

    let detail = helper_error_detail(&output.stderr).map_or_else(
        || format!("helper exited with status {}", output.status),
        str::to_owned,
    );
    if detail.contains("Screen Recording permission not granted") {
        return Err(AutomationError::ScreenCaptureDenied);
    }
    Err(AutomationError::ScreenshotCaptureFailed { detail })
}

async fn run_json_helper_command(
    program: &OsString,
    args: &[OsString],
) -> Result<Vec<u8>, AutomationError> {
    let output = run_helper_command(program, args).await?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let detail = helper_error_detail(&output.stderr).map_or_else(
        || format!("helper exited with status {}", output.status),
        str::to_owned,
    );
    if detail.contains("Screen Recording permission not granted") {
        return Err(AutomationError::ScreenCaptureDenied);
    }
    Err(AutomationError::ScreenshotCaptureFailed { detail })
}

async fn harness_input_path() -> Result<OsString, AutomationError> {
    match detect_backend().await {
        Backend::HarnessInput(path) => Ok(path.as_os_str().to_owned()),
        Backend::Cliclick | Backend::None => Err(AutomationError::ScreenshotBackendMissing),
    }
}

fn parse_shareable_window_ids(output: &[u8]) -> Result<Vec<u32>, AutomationError> {
    let parsed: ShareableWindowList = serde_json::from_slice(output).map_err(|error| {
        AutomationError::ScreenshotCaptureFailed {
            detail: format!("invalid helper JSON: {error}"),
        }
    })?;
    Ok(parsed.window_ids)
}

async fn run_helper_command(
    program: &OsString,
    args: &[OsString],
) -> Result<Output, AutomationError> {
    timeout(
        SCREENSHOT_CAPTURE_TIMEOUT,
        Command::new(program).args(args).kill_on_drop(true).output(),
    )
    .await
    .map_err(|_| AutomationError::ScreenshotCaptureTimedOut {
        milliseconds: SCREENSHOT_CAPTURE_TIMEOUT.as_millis(),
    })?
    .map_err(|error| AutomationError::ScreenshotCaptureFailed {
        detail: error.to_string(),
    })
}

fn helper_error_detail(stderr: &[u8]) -> Option<&str> {
    let raw = str::from_utf8(stderr).ok()?.trim();
    if raw.is_empty() {
        return None;
    }
    Some(raw.strip_prefix("error: ").unwrap_or(raw))
}
