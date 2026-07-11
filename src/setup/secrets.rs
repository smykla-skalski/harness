//! `harness setup secrets` — diagnostics and writes for task-board secrets.
//!
//! Talks to the macOS Keychain via `security-framework`, so secret values
//! never reach a subprocess argv: callers supply them via stdin, file, or
//! environment variable (precedence in that order), and from there the bytes
//! ride a `SecKeychainItem*` buffer into `Security.framework` directly.

#[cfg(target_os = "macos")]
use std::io::{self, Read};
#[cfg(target_os = "macos")]
use std::{env, fs};

use clap::{Args, Subcommand, ValueEnum};
#[cfg(target_os = "macos")]
use security_framework::base::Error as SecError;
#[cfg(target_os = "macos")]
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};
#[cfg(any(target_os = "macos", test))]
use sha1::{Digest, Sha1};

use crate::app::command_context::AppContext;
use crate::errors::{CliError, CliErrorKind};

#[cfg(any(target_os = "macos", test))]
const SERVICE_GITHUB: &str = "io.harnessmonitor.task-board.github-credentials";
#[cfg(any(target_os = "macos", test))]
const SERVICE_TODOIST: &str = "io.harnessmonitor.task-board.todoist-credentials";
#[cfg(any(target_os = "macos", test))]
const SERVICE_SSH: &str = "io.harnessmonitor.task-board.ssh-key";
#[cfg(any(target_os = "macos", test))]
const SERVICE_SIGNING_SSH: &str = "io.harnessmonitor.task-board.signing-ssh-key";
#[cfg(any(target_os = "macos", test))]
const SERVICE_GPG: &str = "io.harnessmonitor.task-board.gpg-key";
#[cfg(any(target_os = "macos", test))]
const SERVICE_OPENROUTER: &str = "io.harnessmonitor.task-board.openrouter-credentials";

#[derive(Debug, Clone, Args)]
pub struct SecretsArgs {
    #[command(subcommand)]
    pub command: SecretsCommand,
}

impl SecretsArgs {
    /// Dispatch the secrets subcommand.
    ///
    /// # Errors
    /// Returns `CliError` only when the underlying subcommand returns one.
    pub fn execute(&self, _ctx: &AppContext) -> Result<i32, CliError> {
        #[cfg(target_os = "macos")]
        {
            match &self.command {
                SecretsCommand::List => Ok(run_list()),
                SecretsCommand::Set(args) => run_set(args),
                SecretsCommand::Clear(args) => run_clear(args),
                SecretsCommand::Test(args) => run_test(args),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(
                CliErrorKind::workflow_io("setup secrets requires the macOS Keychain".to_string())
                    .into(),
            )
        }
    }
}

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SecretsCommand {
    /// Report which task-board credentials are configured in your Keychain.
    List,
    /// Store a task-board secret in your Keychain. Reads the secret from
    /// stdin (default), a file with `--file`, or an env var with `--env-var`.
    Set(SecretMutateArgs),
    /// Remove a task-board secret from your Keychain.
    Clear(SecretScopeArgs),
    /// Check whether a task-board secret is present without revealing it.
    Test(SecretScopeArgs),
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum SecretKindArg {
    /// GitHub personal access token.
    Github,
    /// Todoist API token.
    Todoist,
    /// SSH private key used for git transport authentication.
    Ssh,
    /// SSH private key used for commit/tag signing.
    SigningSsh,
    /// GPG private key used for commit/tag signing.
    Gpg,
    /// `OpenRouter` API key for the in-daemon `OpenRouter` agent backend.
    OpenRouter,
}

#[derive(Debug, Clone, Args)]
pub struct SecretScopeArgs {
    /// Which secret to act on.
    #[arg(long, value_enum)]
    pub kind: SecretKindArg,
    /// Repository slug `owner/repo` for a per-repo override. Omit for the
    /// global scope.
    #[arg(long)]
    pub repository: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct SecretMutateArgs {
    #[command(flatten)]
    pub scope: SecretScopeArgs,
    /// Read the secret value from this file path (mutually exclusive with
    /// `--env-var`).
    #[arg(long, conflicts_with = "env_var")]
    pub file: Option<String>,
    /// Read the secret value from this environment variable (mutually
    /// exclusive with `--file`).
    #[arg(long)]
    pub env_var: Option<String>,
}

#[cfg(target_os = "macos")]
fn run_list() -> i32 {
    let entries = [
        ("GitHub token", SERVICE_GITHUB, "default"),
        ("Todoist token", SERVICE_TODOIST, "default"),
        ("SSH key (global)", SERVICE_SSH, "global"),
        ("Signing SSH key (global)", SERVICE_SIGNING_SSH, "global"),
        ("GPG key (global)", SERVICE_GPG, "global"),
        ("OpenRouter token", SERVICE_OPENROUTER, "default"),
    ];
    println!("Task-board credential status (Keychain):");
    for (label, service, account) in entries {
        let status = if keychain_item_present(service, account) {
            "configured"
        } else {
            "not configured"
        };
        println!("  {label}: {status}");
    }
    0
}

#[cfg(target_os = "macos")]
fn run_set(args: &SecretMutateArgs) -> Result<i32, CliError> {
    let (service, account) = resolve_service_account(&args.scope)?;
    let secret = read_secret(args)?;
    if secret.is_empty() {
        return Err(CliError::from(CliErrorKind::workflow_parse(
            "refusing to store an empty secret; use `clear` to remove instead",
        )));
    }
    set_generic_password(service, account.as_str(), secret.as_bytes())
        .map_err(|error| keychain_error("write", service, account.as_str(), error))?;
    println!("Stored {service} ({account})");
    Ok(0)
}

#[cfg(target_os = "macos")]
fn run_clear(args: &SecretScopeArgs) -> Result<i32, CliError> {
    let (service, account) = resolve_service_account(args)?;
    match delete_generic_password(service, account.as_str()) {
        Ok(()) => {
            println!("Cleared {service} ({account})");
            Ok(0)
        }
        Err(error) if is_not_found(error) => {
            println!("Nothing to clear for {service} ({account})");
            Ok(0)
        }
        Err(error) => Err(keychain_error("clear", service, account.as_str(), error)),
    }
}

#[cfg(target_os = "macos")]
fn run_test(args: &SecretScopeArgs) -> Result<i32, CliError> {
    let (service, account) = resolve_service_account(args)?;
    if keychain_item_present(service, account.as_str()) {
        println!("present: {service} ({account})");
        Ok(0)
    } else {
        println!("missing: {service} ({account})");
        Ok(1)
    }
}

#[cfg(target_os = "macos")]
fn keychain_error(action: &str, service: &str, account: &str, error: SecError) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "Keychain {action} failed for {service} ({account}): {error}"
    )))
}

/// errSecItemNotFound on macOS.
#[cfg(target_os = "macos")]
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

#[cfg(target_os = "macos")]
fn is_not_found(error: SecError) -> bool {
    error.code() == ERR_SEC_ITEM_NOT_FOUND
}

#[cfg(any(target_os = "macos", test))]
fn resolve_service_account(args: &SecretScopeArgs) -> Result<(&'static str, String), CliError> {
    let (service, global_account) = match args.kind {
        SecretKindArg::Github => (SERVICE_GITHUB, "default"),
        SecretKindArg::Todoist => (SERVICE_TODOIST, "default"),
        SecretKindArg::Ssh => (SERVICE_SSH, "global"),
        SecretKindArg::SigningSsh => (SERVICE_SIGNING_SSH, "global"),
        SecretKindArg::Gpg => (SERVICE_GPG, "global"),
        SecretKindArg::OpenRouter => (SERVICE_OPENROUTER, "default"),
    };
    let account = if let Some(slug) = args.repository.as_deref() {
        let normalized = normalize_repository_slug(slug)?;
        format!("repo.{}", sha1_hex(&normalized))
    } else {
        global_account.to_owned()
    };
    Ok((service, account))
}

#[cfg(target_os = "macos")]
fn read_secret(args: &SecretMutateArgs) -> Result<String, CliError> {
    if let Some(path) = &args.file {
        fs::read_to_string(path)
            .map(|s| s.trim_end_matches('\n').to_owned())
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "failed to read secret from {path}: {error}"
                )))
            })
    } else if let Some(var) = &args.env_var {
        env::var(var).map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "failed to read secret from env var {var}: {error}"
            )))
        })
    } else {
        let mut buffer = String::new();
        io::stdin().read_to_string(&mut buffer).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "failed to read secret from stdin: {error}"
            )))
        })?;
        Ok(buffer.trim_end_matches('\n').to_owned())
    }
}

#[cfg(any(target_os = "macos", test))]
fn normalize_repository_slug(slug: &str) -> Result<String, CliError> {
    let trimmed = slug.trim();
    if trimmed.is_empty() || !trimmed.contains('/') {
        return Err(CliError::from(CliErrorKind::workflow_parse(format!(
            "invalid repository slug '{slug}', expected owner/repo"
        ))));
    }
    Ok(trimmed.to_lowercase())
}

#[cfg(any(target_os = "macos", test))]
fn sha1_hex(value: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(value.as_bytes());
    hex::encode(hasher.finalize())
}

#[cfg(target_os = "macos")]
fn keychain_item_present(service: &str, account: &str) -> bool {
    get_generic_password(service, account).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha1_matches_swift_insecure_sha1_hex() {
        assert_eq!(
            sha1_hex("owner/repo"),
            "b0a93768b870824e04990d714ca1b761394528c1"
        );
    }

    #[test]
    fn normalize_repository_slug_lowercases_and_validates() {
        assert_eq!(
            normalize_repository_slug("OWNER/REPO").unwrap(),
            "owner/repo"
        );
        assert!(normalize_repository_slug("no-slash").is_err());
        assert!(normalize_repository_slug("  ").is_err());
    }

    #[test]
    fn resolve_service_account_uses_global_when_no_repository() {
        let args = SecretScopeArgs {
            kind: SecretKindArg::Github,
            repository: None,
        };
        let (service, account) = resolve_service_account(&args).unwrap();
        assert_eq!(service, SERVICE_GITHUB);
        assert_eq!(account, "default");
    }

    #[test]
    fn resolve_service_account_hashes_repository_slug() {
        let args = SecretScopeArgs {
            kind: SecretKindArg::Ssh,
            repository: Some("OWNER/REPO".into()),
        };
        let (service, account) = resolve_service_account(&args).unwrap();
        assert_eq!(service, SERVICE_SSH);
        assert_eq!(account, "repo.b0a93768b870824e04990d714ca1b761394528c1");
    }

    #[test]
    fn resolve_service_account_supports_openrouter() {
        let args = SecretScopeArgs {
            kind: SecretKindArg::OpenRouter,
            repository: None,
        };
        let (service, account) = resolve_service_account(&args).unwrap();
        assert_eq!(service, SERVICE_OPENROUTER);
        assert_eq!(account, "default");
    }
}
