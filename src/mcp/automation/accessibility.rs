use std::ffi::OsString;
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use thiserror::Error;
use tokio::process::Command;
use tokio::time::{Duration, timeout};

use crate::mcp::registry::{ElementKind, GetElementResult, ListElementsResult};

use super::backend::{Backend, detect_backend};

// Keep helper fallback queries bounded so a wedged AX tree degrades to a fast
// MCP error instead of hanging the whole request path.
const ACCESSIBILITY_QUERY_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Error)]
pub enum AccessibilityQueryError {
    #[error(
        "Accessibility query helper unavailable. Build the bundled helper with `swift build -c \
         release --package-path mcp-servers/harness-monitor-registry --product harness-monitor-input`."
    )]
    HelperMissing,
    #[error(
        "Accessibility permission not granted. Open System Settings -> Privacy & Security -> \
         Accessibility and enable the app running this MCP server."
    )]
    AccessibilityDenied,
    #[error("accessibility element not found")]
    NotFound,
    #[error("accessibility query failed: {detail}")]
    QueryFailed { detail: String },
    #[error("accessibility query timed out after {milliseconds}ms")]
    TimedOut { milliseconds: u128 },
    #[error("accessibility query decode failed: {detail}")]
    DecodeFailed { detail: String },
}

pub async fn list_elements(
    window_id: Option<i64>,
    kind: Option<ElementKind>,
) -> Result<ListElementsResult, AccessibilityQueryError> {
    let program = helper_program().await?;
    let args = list_elements_args(window_id, kind);
    run_query(&program, &args).await
}

pub async fn get_element(identifier: &str) -> Result<GetElementResult, AccessibilityQueryError> {
    let program = helper_program().await?;
    let args = get_element_args(identifier);
    run_query(&program, &args).await
}

#[must_use]
pub fn list_elements_args(window_id: Option<i64>, kind: Option<ElementKind>) -> Vec<OsString> {
    let mut args = vec![OsString::from("list-elements")];
    if let Some(window_id) = window_id {
        args.push(OsString::from("--window-id"));
        args.push(OsString::from(window_id.to_string()));
    }
    if let Some(kind) = kind {
        args.push(OsString::from("--kind"));
        args.push(OsString::from(kind.as_wire()));
    }
    args
}

#[must_use]
pub fn get_element_args(identifier: &str) -> Vec<OsString> {
    vec![OsString::from("get-element"), OsString::from(identifier)]
}

async fn helper_program() -> Result<PathBuf, AccessibilityQueryError> {
    match detect_backend().await {
        Backend::HarnessInput(path) => Ok(path),
        Backend::Cliclick | Backend::None => Err(AccessibilityQueryError::HelperMissing),
    }
}

async fn run_query<T: DeserializeOwned>(
    program: &PathBuf,
    args: &[OsString],
) -> Result<T, AccessibilityQueryError> {
    run_query_with_timeout(program, args, ACCESSIBILITY_QUERY_TIMEOUT).await
}

async fn run_query_with_timeout<T: DeserializeOwned>(
    program: &PathBuf,
    args: &[OsString],
    deadline: Duration,
) -> Result<T, AccessibilityQueryError> {
    let output = timeout(
        deadline,
        Command::new(program).args(args).kill_on_drop(true).output(),
    )
    .await
    .map_err(|_| AccessibilityQueryError::TimedOut {
        milliseconds: deadline.as_millis(),
    })?
    .map_err(|error| AccessibilityQueryError::QueryFailed {
        detail: error.to_string(),
    })?;
    if !output.status.success() {
        return Err(map_query_failure(&output));
    }
    serde_json::from_slice(&output.stdout).map_err(|error| AccessibilityQueryError::DecodeFailed {
        detail: error.to_string(),
    })
}

fn map_query_failure(output: &std::process::Output) -> AccessibilityQueryError {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr.trim();
    match output.status.code() {
        Some(2) => AccessibilityQueryError::AccessibilityDenied,
        Some(3) => AccessibilityQueryError::NotFound,
        _ if detail.contains("Accessibility permission not granted") => {
            AccessibilityQueryError::AccessibilityDenied
        }
        _ if detail.contains("not found:") => AccessibilityQueryError::NotFound,
        _ => AccessibilityQueryError::QueryFailed {
            detail: if detail.is_empty() {
                "helper exited without stderr".to_string()
            } else {
                detail.to_string()
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    fn write_helper_script(path: &std::path::Path, body: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create helper parent");
        }
        fs::write(path, body).expect("write helper script");
        let mut permissions = fs::metadata(path).expect("helper metadata").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("set helper executable");
    }

    #[tokio::test]
    async fn run_query_times_out_hanging_helper() {
        let temp = tempfile::tempdir().expect("tempdir");
        let helper = temp.path().join("harness-monitor-input");
        write_helper_script(&helper, "#!/bin/sh\nsleep 60\n");

        let result = run_query_with_timeout::<ListElementsResult>(
            &helper,
            &[OsString::from("list-elements")],
            Duration::from_millis(50),
        )
        .await;

        assert_eq!(
            result.unwrap_err().to_string(),
            "accessibility query timed out after 50ms"
        );
    }
}
