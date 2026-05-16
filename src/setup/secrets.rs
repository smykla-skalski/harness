//! `harness setup secrets` — diagnostics for task-board secret state.
//!
//! Reads the macOS Keychain via the bundled `security` CLI so we don't take a
//! new Rust dependency. Currently only the `list` subcommand is implemented;
//! it reports which task-board credentials are configured at the global scope
//! without ever printing the secret material.

use std::process::Command;

use clap::{Args, Subcommand};

use crate::app::command_context::AppContext;
use crate::errors::CliError;

const SERVICE_GITHUB: &str = "io.harnessmonitor.task-board.github-credentials";
const SERVICE_TODOIST: &str = "io.harnessmonitor.task-board.todoist-credentials";
const SERVICE_SSH: &str = "io.harnessmonitor.task-board.ssh-key";
const SERVICE_SIGNING_SSH: &str = "io.harnessmonitor.task-board.signing-ssh-key";
const SERVICE_GPG: &str = "io.harnessmonitor.task-board.gpg-key";

#[derive(Debug, Clone, Args)]
pub struct SecretsArgs {
    #[command(subcommand)]
    pub command: SecretsCommand,
}

impl SecretsArgs {
    /// Dispatch the secrets diagnostic subcommand.
    ///
    /// # Errors
    /// Returns `CliError` only when the underlying subcommand returns one.
    pub fn execute(&self, ctx: &AppContext) -> Result<i32, CliError> {
        match &self.command {
            SecretsCommand::List => run_list(ctx),
        }
    }
}

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SecretsCommand {
    /// Report which task-board credentials are configured in your Keychain.
    List,
}

fn run_list(_ctx: &AppContext) -> Result<i32, CliError> {
    let entries = [
        ("GitHub token", SERVICE_GITHUB, "default"),
        ("Todoist token", SERVICE_TODOIST, "default"),
        ("SSH key (global)", SERVICE_SSH, "global"),
        ("Signing SSH key (global)", SERVICE_SIGNING_SSH, "global"),
        ("GPG key (global)", SERVICE_GPG, "global"),
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
    Ok(0)
}

fn keychain_item_present(service: &str, account: &str) -> bool {
    Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            service,
            "-a",
            account,
        ])
        .output()
        .is_ok_and(|out| out.status.success())
}
