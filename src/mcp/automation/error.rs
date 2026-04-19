use thiserror::Error;

#[derive(Debug, Error)]
pub enum AutomationError {
    #[error(
        "No mouse backend available. Build the bundled helper with `swift build -c release \
         --package-path mcp-servers/harness-monitor-registry --product harness-monitor-input` \
         or install cliclick (`brew install cliclick`). Either way, grant Accessibility permission \
         to the process running this MCP server."
    )]
    MouseBackendMissing,
    #[error(
        "Accessibility permission not granted. Open System Settings -> Privacy & Security -> \
         Accessibility and enable the app running this MCP server."
    )]
    AccessibilityDenied,
    #[error("middle-button clicks are not supported.")]
    UnsupportedButton,
    #[error("input failed: {detail}")]
    InputFailed { detail: String },
    #[error("screencapture failed: {detail}")]
    ScreencaptureFailed { detail: String },
    #[error("screenshot io: {detail}")]
    ScreenshotIo { detail: String },
}

impl AutomationError {
    #[must_use]
    pub fn from_backend_output(stderr: &str) -> Self {
        if stderr.contains("Accessibility permission not granted") {
            Self::AccessibilityDenied
        } else {
            Self::InputFailed {
                detail: stderr.trim().to_string(),
            }
        }
    }
}
