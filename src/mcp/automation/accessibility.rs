use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Output;

use serde::de::DeserializeOwned;
use thiserror::Error;
use tokio::process::Command;
use tokio::time::{Duration, timeout};

use crate::mcp::registry::{ElementKind, GetElementResult, ListElementsResult};

#[cfg(test)]
use super::backend::INPUT_OVERRIDE_ENV;
use super::backend::{Backend, detect_backend};

// Keep helper fallback queries bounded so a wedged AX tree degrades to a fast
// MCP error instead of hanging the whole request path.
const ACCESSIBILITY_QUERY_TIMEOUT: Duration = Duration::from_secs(3);
const ACCESSIBILITY_ACTION_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccessibilityAction {
    Press,
}

impl AccessibilityAction {
    #[must_use]
    pub const fn as_wire(self) -> &'static str {
        match self {
            Self::Press => "press",
        }
    }
}

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

#[derive(Debug, Error)]
pub enum AccessibilityActionError {
    #[error(
        "Accessibility action helper unavailable. Build the bundled helper with `swift build -c \
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
    #[error("accessibility element does not expose a supported default action")]
    ActionUnavailable,
    #[error("accessibility action failed: {detail}")]
    ActionFailed { detail: String },
    #[error("accessibility action timed out after {milliseconds}ms")]
    TimedOut { milliseconds: u128 },
}

/// Resolve elements from the helper backend with optional window/kind filters.
///
/// # Errors
/// Returns `AccessibilityQueryError` when the helper is missing, denied,
/// times out, or returns invalid/failed output.
pub async fn list_elements(
    window_id: Option<i64>,
    kind: Option<ElementKind>,
) -> Result<ListElementsResult, AccessibilityQueryError> {
    let program = helper_program().await?;
    let args = list_elements_args(window_id, kind);
    run_query(&program, &args).await
}

/// Resolve one element by identifier via the helper backend.
///
/// # Errors
/// Returns `AccessibilityQueryError` when the helper is missing, denied,
/// times out, or returns invalid/failed output.
pub async fn get_element(identifier: &str) -> Result<GetElementResult, AccessibilityQueryError> {
    let program = helper_program().await?;
    let args = get_element_args(identifier);
    run_query(&program, &args).await
}

/// Perform a semantic accessibility action on one element by identifier.
///
/// # Errors
/// Returns `AccessibilityActionError` when the helper is missing, denied,
/// times out, or cannot perform the requested action.
pub async fn perform_action(
    identifier: &str,
    window_id: Option<i64>,
    action: AccessibilityAction,
) -> Result<(), AccessibilityActionError> {
    let program = helper_program_for_action().await?;
    match run_action_request(&program, identifier, window_id, action).await {
        Err(AccessibilityActionError::NotFound) if window_id.is_some() => {
            run_action_request(&program, identifier, None, action).await
        }
        result => result,
    }
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

#[must_use]
pub fn perform_action_args(
    identifier: &str,
    window_id: Option<i64>,
    action: AccessibilityAction,
) -> Vec<OsString> {
    let mut args = vec![OsString::from("perform-action")];
    if let Some(window_id) = window_id {
        args.push(OsString::from("--window-id"));
        args.push(OsString::from(window_id.to_string()));
    }
    args.push(OsString::from("--action"));
    args.push(OsString::from(action.as_wire()));
    args.push(OsString::from(identifier));
    args
}

async fn helper_program() -> Result<PathBuf, AccessibilityQueryError> {
    match detect_backend().await {
        Backend::HarnessInput(path) => Ok(path),
        Backend::Cliclick | Backend::None => Err(AccessibilityQueryError::HelperMissing),
    }
}

async fn helper_program_for_action() -> Result<PathBuf, AccessibilityActionError> {
    match detect_backend().await {
        Backend::HarnessInput(path) => Ok(path),
        Backend::Cliclick | Backend::None => Err(AccessibilityActionError::HelperMissing),
    }
}

async fn run_query<T: DeserializeOwned>(
    program: &Path,
    args: &[OsString],
) -> Result<T, AccessibilityQueryError> {
    run_query_with_timeout(program, args, ACCESSIBILITY_QUERY_TIMEOUT).await
}

async fn run_action(program: &Path, args: &[OsString]) -> Result<(), AccessibilityActionError> {
    run_action_with_timeout(program, args, ACCESSIBILITY_ACTION_TIMEOUT).await
}

async fn run_action_request(
    program: &Path,
    identifier: &str,
    window_id: Option<i64>,
    action: AccessibilityAction,
) -> Result<(), AccessibilityActionError> {
    let args = perform_action_args(identifier, window_id, action);
    run_action(program, &args).await
}

async fn run_query_with_timeout<T: DeserializeOwned>(
    program: &Path,
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

async fn run_action_with_timeout(
    program: &Path,
    args: &[OsString],
    deadline: Duration,
) -> Result<(), AccessibilityActionError> {
    let output = timeout(
        deadline,
        Command::new(program).args(args).kill_on_drop(true).output(),
    )
    .await
    .map_err(|_| AccessibilityActionError::TimedOut {
        milliseconds: deadline.as_millis(),
    })?
    .map_err(|error| AccessibilityActionError::ActionFailed {
        detail: error.to_string(),
    })?;
    if !output.status.success() {
        return Err(map_action_failure(&output));
    }
    Ok(())
}

fn map_query_failure(output: &Output) -> AccessibilityQueryError {
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

fn map_action_failure(output: &Output) -> AccessibilityActionError {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr.trim();
    match output.status.code() {
        Some(2) => AccessibilityActionError::AccessibilityDenied,
        Some(3) => AccessibilityActionError::NotFound,
        Some(4) => AccessibilityActionError::ActionUnavailable,
        _ if detail.contains("Accessibility permission not granted") => {
            AccessibilityActionError::AccessibilityDenied
        }
        _ if detail.contains("not found:") => AccessibilityActionError::NotFound,
        _ if detail.contains("no supported accessibility action") => {
            AccessibilityActionError::ActionUnavailable
        }
        _ => AccessibilityActionError::ActionFailed {
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

    fn write_helper_script(path: &Path, body: &str) {
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

    #[tokio::test]
    async fn run_action_times_out_hanging_helper() {
        let temp = tempfile::tempdir().expect("tempdir");
        let helper = temp.path().join("harness-monitor-input");
        write_helper_script(&helper, "#!/bin/sh\nsleep 60\n");

        let result = run_action_with_timeout(
            &helper,
            &[OsString::from("perform-action")],
            Duration::from_millis(50),
        )
        .await;

        assert_eq!(
            result.unwrap_err().to_string(),
            "accessibility action timed out after 50ms"
        );
    }

    #[tokio::test]
    async fn perform_action_retries_without_window_scope_after_scoped_not_found() {
        let temp = tempfile::tempdir().expect("tempdir");
        let helper = temp.path().join("harness-monitor-input");
        let log_path = temp.path().join("perform-action.log");
        let script = format!(
            r#"#!/bin/sh
case "$1" in
  --help|check)
    exit 0
    ;;
  perform-action)
    printf '%s\n' "$*" >> "{log_path}"
    if [ "$*" = "perform-action --window-id 7 --action press button.send" ]; then
      printf 'error: not found: button.send\n' >&2
      exit 3
    fi
    if [ "$*" = "perform-action --action press button.send" ]; then
      exit 0
    fi
    exit 64
    ;;
  *)
    exit 64
    ;;
esac
"#,
            log_path = log_path.to_string_lossy()
        );
        write_helper_script(&helper, &script);
        let helper_path = helper.to_string_lossy().into_owned();

        temp_env::async_with_vars([(INPUT_OVERRIDE_ENV, Some(helper_path.as_str()))], async {
            perform_action("button.send", Some(7), AccessibilityAction::Press)
                .await
                .expect("unscoped retry succeeds");
        })
        .await;

        assert_eq!(
            fs::read_to_string(log_path).expect("read retry log"),
            "perform-action --window-id 7 --action press button.send\nperform-action --action press button.send\n"
        );
    }
}
