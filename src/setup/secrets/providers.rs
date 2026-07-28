use std::str;

use harness_daemon_client::{ClientError, DaemonClient};
use harness_kernel::errors::{CliError, CliErrorKind};
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};

use crate::task_board::wire::TaskBoardCapabilitiesResponse;
use crate::task_board::{
    TaskBoardGitHubCredentialSnapshot, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardOpenRouterCredentialSnapshot,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
};

use super::{
    SERVICE_GITHUB, SERVICE_OPENROUTER, SecretKindArg, SecretScopeArgs, is_not_found,
    keychain_error, sha1_hex,
};

pub(super) fn set_provider_secret(args: &SecretScopeArgs, secret: &str) -> Result<i32, CliError> {
    validate_provider_scope(args)?;
    let client = DaemonClient::try_connect();
    let account = provider_account(client.as_ref())?;
    match args.kind {
        SecretKindArg::Github => {
            let mut snapshot = load_github_snapshot(&account)?;
            snapshot
                .set_token(args.repository.as_deref(), secret)
                .map_err(provider_parse_error)?;
            save_snapshot(SERVICE_GITHUB, &account, &snapshot)?;
            sync_github(client.as_ref(), &snapshot)?;
        }
        SecretKindArg::OpenRouter => {
            let mut snapshot = load_openrouter_snapshot(&account)?;
            snapshot.set_token(secret).map_err(provider_parse_error)?;
            save_snapshot(SERVICE_OPENROUTER, &account, &snapshot)?;
            sync_openrouter(client.as_ref(), &snapshot)?;
        }
        _ => unreachable!("provider secret kind checked by caller"),
    }
    println!("Stored {} ({account})", provider_service(args.kind));
    Ok(0)
}

pub(super) fn clear_provider_secret(args: &SecretScopeArgs) -> Result<i32, CliError> {
    validate_provider_scope(args)?;
    let client = DaemonClient::try_connect();
    let account = provider_account(client.as_ref())?;
    let cleared = match args.kind {
        SecretKindArg::Github => {
            let mut snapshot = load_github_snapshot(&account)?;
            let cleared = snapshot
                .clear_token(args.repository.as_deref())
                .map_err(provider_parse_error)?;
            persist_or_delete(SERVICE_GITHUB, &account, &snapshot, snapshot.is_empty())?;
            sync_github(client.as_ref(), &snapshot)?;
            cleared
        }
        SecretKindArg::OpenRouter => {
            let mut snapshot = load_openrouter_snapshot(&account)?;
            let cleared = snapshot.clear_token();
            persist_or_delete(
                SERVICE_OPENROUTER,
                &account,
                &snapshot,
                !snapshot.is_configured(),
            )?;
            sync_openrouter(client.as_ref(), &snapshot)?;
            cleared
        }
        _ => unreachable!("provider secret kind checked by caller"),
    };
    let action = if cleared {
        "Cleared"
    } else {
        "Nothing to clear for"
    };
    println!("{action} {} ({account})", provider_service(args.kind));
    Ok(0)
}

pub(super) fn provider_account(client: Option<&DaemonClient>) -> Result<String, CliError> {
    let Some(client) = client else {
        return Ok("default".to_string());
    };
    let capabilities = client
        .get::<TaskBoardCapabilitiesResponse>("/v1/task-board/capabilities", &[])
        .map_err(|error| daemon_sync_error("read task-board identity", &error))?;
    Ok(format!("db{}-global", sha1_hex(&capabilities.instance_id)))
}

pub(super) fn provider_configured(
    kind: SecretKindArg,
    repository: Option<&str>,
    account: &str,
) -> Result<bool, CliError> {
    match kind {
        SecretKindArg::Github => Ok(load_github_snapshot(account)?.token_configured(repository)),
        SecretKindArg::OpenRouter => {
            if repository.is_some() {
                return Err(provider_parse_error(
                    "OpenRouter credentials do not support repository scope".to_string(),
                ));
            }
            Ok(load_openrouter_snapshot(account)?.is_configured())
        }
        _ => unreachable!("provider credential kind required"),
    }
}

pub(super) fn provider_any_configured(
    kind: SecretKindArg,
    account: &str,
) -> Result<bool, CliError> {
    match kind {
        SecretKindArg::Github => Ok(load_github_snapshot(account)?.is_configured()),
        SecretKindArg::OpenRouter => Ok(load_openrouter_snapshot(account)?.is_configured()),
        _ => unreachable!("provider credential kind required"),
    }
}

pub(super) fn provider_service(kind: SecretKindArg) -> &'static str {
    match kind {
        SecretKindArg::Github => SERVICE_GITHUB,
        SecretKindArg::OpenRouter => SERVICE_OPENROUTER,
        _ => unreachable!("provider credential kind required"),
    }
}

fn validate_provider_scope(args: &SecretScopeArgs) -> Result<(), CliError> {
    if matches!(args.kind, SecretKindArg::OpenRouter) && args.repository.is_some() {
        return Err(provider_parse_error(
            "OpenRouter credentials do not support repository scope".to_string(),
        ));
    }
    Ok(())
}

fn load_github_snapshot(account: &str) -> Result<TaskBoardGitHubCredentialSnapshot, CliError> {
    load_snapshot(SERVICE_GITHUB, account, |bytes, allow_legacy_raw| {
        if let Ok(snapshot) = serde_json::from_slice(bytes) {
            return Ok(snapshot);
        }
        if !allow_legacy_raw {
            return Err("expected a JSON credential snapshot".to_string());
        }
        legacy_raw_token(bytes)
            .map(|token| TaskBoardGitHubCredentialSnapshot {
                global_token: Some(token),
                repository_tokens: Vec::new(),
            })
    })
}

fn load_openrouter_snapshot(
    account: &str,
) -> Result<TaskBoardOpenRouterCredentialSnapshot, CliError> {
    load_snapshot(SERVICE_OPENROUTER, account, |bytes, allow_legacy_raw| {
        if let Ok(snapshot) = serde_json::from_slice(bytes) {
            return Ok(snapshot);
        }
        if !allow_legacy_raw {
            return Err("expected a JSON credential snapshot".to_string());
        }
        legacy_raw_token(bytes)
            .map(|token| TaskBoardOpenRouterCredentialSnapshot { token: Some(token) })
    })
}

fn load_snapshot<T>(
    service: &str,
    account: &str,
    parse: impl FnOnce(&[u8], bool) -> Result<T, String>,
) -> Result<T, CliError>
where
    T: Default,
{
    match get_generic_password(service, account) {
        Ok(bytes) => parse(&bytes, account == "default").map_err(|error| {
            provider_parse_error(format!(
                "stored {service} credential is unreadable: {error}"
            ))
        }),
        Err(error) if is_not_found(error) && account != "default" => {
            load_snapshot(service, "default", parse)
        }
        Err(error) if is_not_found(error) => Ok(T::default()),
        Err(error) => Err(keychain_error("read", service, account, error)),
    }
}

fn legacy_raw_token(bytes: &[u8]) -> Result<String, String> {
    str::from_utf8(bytes)
        .map(str::trim)
        .map_err(|_| "legacy credential is invalid UTF-8".to_string())
        .and_then(|token| {
            (!token.is_empty())
                .then(|| token.to_owned())
                .ok_or_else(|| "legacy credential is empty".to_string())
        })
}

fn save_snapshot(
    service: &str,
    account: &str,
    snapshot: &impl serde::Serialize,
) -> Result<(), CliError> {
    let bytes = serde_json::to_vec(snapshot)
        .map_err(|error| provider_parse_error(format!("encode {service} credential: {error}")))?;
    set_generic_password(service, account, &bytes)
        .map_err(|error| keychain_error("write", service, account, error))?;
    clear_legacy_after_scoped_write(service, account)
}

fn persist_or_delete(
    service: &str,
    account: &str,
    snapshot: &impl serde::Serialize,
    empty: bool,
) -> Result<(), CliError> {
    if !empty {
        return save_snapshot(service, account, snapshot);
    }
    match delete_generic_password(service, account) {
        Ok(()) => Ok(()),
        Err(error) if is_not_found(error) => Ok(()),
        Err(error) => Err(keychain_error("clear", service, account, error)),
    }?;
    clear_legacy_after_scoped_write(service, account)
}

fn clear_legacy_after_scoped_write(service: &str, account: &str) -> Result<(), CliError> {
    if account == "default" {
        return Ok(());
    }
    match delete_generic_password(service, "default") {
        Ok(()) => Ok(()),
        Err(error) if is_not_found(error) => Ok(()),
        Err(error) => Err(keychain_error("clear legacy", service, "default", error)),
    }
}

fn sync_github(
    client: Option<&DaemonClient>,
    snapshot: &TaskBoardGitHubCredentialSnapshot,
) -> Result<(), CliError> {
    let Some(client) = client else {
        return Ok(());
    };
    client
        .put::<_, TaskBoardGitHubTokensSyncResponse>(
            "/v1/task-board/orchestrator/github-tokens",
            &TaskBoardGitHubTokensSyncRequest {
                global_token: snapshot.global_token.clone(),
                repository_tokens: snapshot.repository_tokens.clone(),
            },
        )
        .map(|_| ())
        .map_err(|error| daemon_sync_error("refresh GitHub credentials", &error))
}

fn sync_openrouter(
    client: Option<&DaemonClient>,
    snapshot: &TaskBoardOpenRouterCredentialSnapshot,
) -> Result<(), CliError> {
    let Some(client) = client else {
        return Ok(());
    };
    client
        .put::<_, TaskBoardOpenRouterTokenSyncResponse>(
            "/v1/task-board/orchestrator/openrouter-token",
            &TaskBoardOpenRouterTokenSyncRequest {
                token: snapshot.token.clone(),
            },
        )
        .map(|_| ())
        .map_err(|error| daemon_sync_error("refresh OpenRouter credentials", &error))
}

fn provider_parse_error(message: String) -> CliError {
    CliErrorKind::workflow_parse(message).into()
}

fn daemon_sync_error(operation: &str, error: &ClientError) -> CliError {
    CliErrorKind::workflow_io(format!("daemon {operation}: {error}")).into()
}

#[cfg(test)]
mod tests {
    use super::legacy_raw_token;

    #[test]
    fn legacy_raw_token_trims_without_exposing_the_value() {
        assert_eq!(
            legacy_raw_token(b" secret \n").expect("legacy token"),
            "secret"
        );
        assert_eq!(
            legacy_raw_token(b" \n").expect_err("blank token"),
            "legacy credential is empty"
        );
        assert_eq!(
            legacy_raw_token(&[0xff]).expect_err("invalid token"),
            "legacy credential is invalid UTF-8"
        );
    }
}
