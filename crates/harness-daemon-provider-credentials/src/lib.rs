//! Loads GitHub and `OpenRouter` provider credentials from the macOS Keychain
//! at daemon startup and persists them through `harness-daemon-state`,
//! converting into `harness-task-board`'s own credential-snapshot and
//! sync-request types.
//!
//! `db`'s `AsyncDaemonDb` type still lives inside `harness-daemon` itself, so
//! depending on it here would recreate the daemon-crate dependency this
//! extraction exists to remove. The daemon's own startup sequence resolves
//! the task-board instance id and passes it in as a plain string instead.

#[cfg(all(target_os = "macos", not(test)))]
use harness_daemon_state::{replace_task_board_github_tokens, replace_task_board_openrouter_token};
#[cfg(all(target_os = "macos", not(test)))]
use harness_task_board::{
    TaskBoardGitHubCredentialSnapshot, TaskBoardGitHubTokensSyncRequest,
    TaskBoardOpenRouterCredentialSnapshot, TaskBoardOpenRouterTokenSyncRequest,
};
#[cfg(all(target_os = "macos", not(test)))]
use security_framework::base::Error as SecError;
#[cfg(all(target_os = "macos", not(test)))]
use security_framework::passwords::get_generic_password;
use sha1::{Digest, Sha1};

#[cfg(all(target_os = "macos", not(test)))]
const SERVICE_GITHUB: &str = "io.harnessmonitor.task-board.github-credentials";
#[cfg(all(target_os = "macos", not(test)))]
const SERVICE_OPENROUTER: &str = "io.harnessmonitor.task-board.openrouter-credentials";
#[cfg(all(target_os = "macos", not(test)))]
const LEGACY_ACCOUNT: &str = "default";

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProviderCredentialStatus {
    configured: bool,
    source: ProviderCredentialSource,
    error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProviderCredentialSource {
    #[cfg(all(target_os = "macos", not(test)))]
    Database,
    #[cfg(all(target_os = "macos", not(test)))]
    Legacy,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProviderCredentialLoadReport {
    github: ProviderCredentialStatus,
    openrouter: ProviderCredentialStatus,
}

impl Default for ProviderCredentialLoadReport {
    fn default() -> Self {
        Self {
            github: unavailable_status(None),
            openrouter: unavailable_status(None),
        }
    }
}

/// Loads GitHub and `OpenRouter` provider credentials for `instance_id` from
/// the macOS Keychain and persists them through `harness-daemon-state`.
pub fn load_provider_credentials(instance_id: &str) {
    let report = load_for_instance(instance_id);
    log_load_issue("GitHub", &report.github);
    log_load_issue("OpenRouter", &report.openrouter);
}

// Only `load_for_instance` (macOS, non-test) calls this in production; the
// hash format itself stays cross-platform testable via
// `database_account_matches_monitor_scope` below, so a non-macOS,
// non-test build (e.g. `--features full-runtime` on Linux) sees no caller
// at all.
#[must_use]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn database_credential_account(instance_id: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(instance_id.as_bytes());
    format!("db{}-global", hex::encode(hasher.finalize()))
}

fn log_load_issue(provider: &str, status: &ProviderCredentialStatus) {
    if let Some(error) = status.error.as_deref() {
        tracing::warn!(provider, %error, "provider credential unavailable");
    } else if status.source != ProviderCredentialSource::Unavailable {
        tracing::info!(
            provider,
            configured = status.configured,
            source = ?status.source,
            "provider credential loaded"
        );
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn load_for_instance(instance_id: &str) -> ProviderCredentialLoadReport {
    let account = database_credential_account(instance_id);
    let (github, github_status) = load_snapshot(
        SERVICE_GITHUB,
        &account,
        parse_github_snapshot,
        |raw| TaskBoardGitHubCredentialSnapshot {
            global_token: Some(raw.to_owned()),
            repository_tokens: Vec::new(),
        },
        TaskBoardGitHubCredentialSnapshot::is_configured,
    );
    let (openrouter, openrouter_status) = load_snapshot(
        SERVICE_OPENROUTER,
        &account,
        parse_openrouter_snapshot,
        |raw| TaskBoardOpenRouterCredentialSnapshot {
            token: Some(raw.to_owned()),
        },
        TaskBoardOpenRouterCredentialSnapshot::is_configured,
    );
    if let Some(snapshot) = github {
        let _ = replace_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
            global_token: snapshot.global_token,
            repository_tokens: snapshot.repository_tokens,
        });
    }
    if let Some(snapshot) = openrouter {
        let _ = replace_task_board_openrouter_token(&TaskBoardOpenRouterTokenSyncRequest {
            token: snapshot.token,
        });
    }
    ProviderCredentialLoadReport {
        github: github_status,
        openrouter: openrouter_status,
    }
}

#[cfg(any(not(target_os = "macos"), test))]
fn load_for_instance(_instance_id: &str) -> ProviderCredentialLoadReport {
    ProviderCredentialLoadReport::default()
}

#[cfg(all(target_os = "macos", not(test)))]
fn load_snapshot<T>(
    service: &str,
    database_account: &str,
    parse: fn(&[u8]) -> Result<T, String>,
    legacy_raw: fn(&str) -> T,
    configured: fn(&T) -> bool,
) -> (Option<T>, ProviderCredentialStatus) {
    match read_keychain(service, database_account) {
        Ok(Some(bytes)) => snapshot_result(
            parse(&bytes),
            ProviderCredentialSource::Database,
            configured,
        ),
        Ok(None) => match read_keychain(service, LEGACY_ACCOUNT) {
            Ok(Some(bytes)) => {
                let parsed = parse(&bytes).or_else(|_| {
                    std::str::from_utf8(&bytes)
                        .ok()
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(legacy_raw)
                        .ok_or_else(|| "stored credential payload is unreadable".to_string())
                });
                snapshot_result(parsed, ProviderCredentialSource::Legacy, configured)
            }
            Ok(None) => (
                None,
                ProviderCredentialStatus {
                    configured: false,
                    source: ProviderCredentialSource::Unavailable,
                    error: None,
                },
            ),
            Err(error) => (None, unavailable_status(Some(error))),
        },
        Err(error) => (None, unavailable_status(Some(error))),
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn snapshot_result<T>(
    snapshot: Result<T, String>,
    source: ProviderCredentialSource,
    configured: fn(&T) -> bool,
) -> (Option<T>, ProviderCredentialStatus) {
    match snapshot {
        Ok(snapshot) => {
            let is_configured = configured(&snapshot);
            (
                Some(snapshot),
                ProviderCredentialStatus {
                    configured: is_configured,
                    source,
                    error: None,
                },
            )
        }
        Err(error) => (None, unavailable_status(Some(error))),
    }
}

fn unavailable_status(error: Option<String>) -> ProviderCredentialStatus {
    ProviderCredentialStatus {
        configured: false,
        source: ProviderCredentialSource::Unavailable,
        error,
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn read_keychain(service: &str, account: &str) -> Result<Option<Vec<u8>>, String> {
    match get_generic_password(service, account) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if is_not_found(error) => Ok(None),
        Err(error) => Err(format!(
            "read Keychain credential for {service} ({account}): {error}"
        )),
    }
}

#[cfg(all(target_os = "macos", not(test)))]
fn is_not_found(error: SecError) -> bool {
    error.code() == -25300
}

#[cfg(all(target_os = "macos", not(test)))]
fn parse_github_snapshot(bytes: &[u8]) -> Result<TaskBoardGitHubCredentialSnapshot, String> {
    serde_json::from_slice(bytes)
        .map_err(|error| format!("stored GitHub credential payload is unreadable: {error}"))
}

#[cfg(all(target_os = "macos", not(test)))]
fn parse_openrouter_snapshot(
    bytes: &[u8],
) -> Result<TaskBoardOpenRouterCredentialSnapshot, String> {
    serde_json::from_slice(bytes)
        .map_err(|error| format!("stored OpenRouter credential payload is unreadable: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn database_account_matches_monitor_scope() {
        assert_eq!(
            database_credential_account("instance-a"),
            "db494d457064c8f758be3fb586cae947b918468bf7-global"
        );
    }

    #[test]
    fn default_report_exposes_unavailable_without_claiming_configuration() {
        let report = ProviderCredentialLoadReport::default();
        assert!(!report.github.configured);
        assert_eq!(
            report.openrouter.source,
            ProviderCredentialSource::Unavailable
        );
    }
}
