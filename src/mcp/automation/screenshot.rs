use std::ffi::OsString;
use std::path::Path;

use tempfile::TempDir;
use tokio::fs;
use tokio::process::Command;

use super::error::AutomationError;

const SCREENCAPTURE_BIN: &str = "/usr/sbin/screencapture";

#[derive(Debug, Clone, Default)]
pub struct ScreenshotOptions {
    pub window_id: Option<u32>,
    pub display_id: Option<u32>,
    pub include_cursor: bool,
}

/// Build the argv for `/usr/sbin/screencapture` for a given options set and
/// output path. `-x` silences the shutter sound; `-t png` sets PNG output.
#[must_use]
pub fn screencapture_args(options: &ScreenshotOptions, output: &Path) -> Vec<OsString> {
    let mut args: Vec<OsString> = vec![
        OsString::from("-x"),
        OsString::from("-t"),
        OsString::from("png"),
    ];
    if let Some(window) = options.window_id {
        args.push(OsString::from("-l"));
        args.push(OsString::from(window.to_string()));
    } else if let Some(display) = options.display_id {
        args.push(OsString::from("-D"));
        args.push(OsString::from(display.to_string()));
    }
    if options.include_cursor {
        args.push(OsString::from("-C"));
    }
    args.push(OsString::from(output));
    args
}

/// Capture a PNG screenshot. Returns the raw bytes. The temp dir is
/// dropped on return, cleaning up the intermediate file.
///
/// # Errors
/// Returns `AutomationError` when `screencapture` fails or the file cannot
/// be read back.
pub async fn screenshot(options: &ScreenshotOptions) -> Result<Vec<u8>, AutomationError> {
    let dir = TempDir::new().map_err(|error| AutomationError::ScreenshotIo {
        detail: error.to_string(),
    })?;
    let path = dir.path().join("screenshot.png");
    let args = screencapture_args(options, &path);
    let output = Command::new(SCREENCAPTURE_BIN)
        .args(&args)
        .output()
        .await
        .map_err(|error| AutomationError::ScreencaptureFailed {
            detail: error.to_string(),
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(AutomationError::ScreencaptureFailed { detail: stderr });
    }
    fs::read(&path)
        .await
        .map_err(|error| AutomationError::ScreenshotIo {
            detail: error.to_string(),
        })
}
