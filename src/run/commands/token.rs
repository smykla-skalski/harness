use std::borrow::Cow;
use std::path::PathBuf;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::token::parse_token_response;
use crate::infra::exec;
use crate::run::args::RunDirArgs;

use super::kumactl::find_kumactl_binary;
use super::shared::resolve_run_application;

impl Execute for TokenArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        token(
            &self.kind,
            &self.name,
            &self.mesh,
            self.cp_addr.as_deref(),
            &self.valid_for,
            &self.run_dir,
        )
    }
}

/// Arguments for `harness run kuma token`.
#[derive(Debug, Clone, Args)]
pub struct TokenArgs {
    /// Token kind: dataplane, ingress, or egress.
    #[arg(value_parser = ["dataplane", "ingress", "egress"])]
    pub kind: String,
    /// Dataplane name.
    #[arg(long)]
    pub name: String,
    /// Mesh name.
    #[arg(long, default_value = "default")]
    pub mesh: String,
    /// CP API address (auto-detected from run context if omitted).
    #[arg(long)]
    pub cp_addr: Option<String>,
    /// Token validity duration.
    #[arg(long, default_value = "24h")]
    pub valid_for: String,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Generate a dataplane token from the control plane.
///
/// Tries the REST API first, falls back to kumactl.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn token(
    kind: &str,
    name: &str,
    mesh: &str,
    cp_addr: Option<&str>,
    valid_for: &str,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run = resolve_run_application(run_dir_args)?;
    let access = run.control_plane_access()?;
    let addr = cp_addr.map_or(access.addr, Cow::Borrowed);
    let admin_token = access.admin_token;
    let token =
        token_via_api(addr.as_ref(), kind, name, mesh, valid_for, admin_token).or_else(|_| {
            token_via_kumactl(
                &run.metadata().repo_root,
                addr.as_ref(),
                kind,
                name,
                mesh,
                valid_for,
            )
        })?;
    println!("{token}");
    Ok(0)
}

fn token_via_kumactl(
    repo_root: &str,
    addr: &str,
    kind: &str,
    name: &str,
    mesh: &str,
    valid_for: &str,
) -> Result<String, CliError> {
    let root = PathBuf::from(repo_root);
    let binary = find_kumactl_binary(&root)?;
    let args = kumactl_token_args(kind, name, mesh, valid_for);
    let result = exec::kumactl_run(&binary, addr, &args, &[0])?;
    parse_token_response(&result.stdout)
        .map(|response| response.token)
        .map_err(|error| CliErrorKind::token_generation_failed(error.to_string()).into())
}

fn kumactl_token_args<'a>(
    kind: &'a str,
    name: &'a str,
    mesh: &'a str,
    valid_for: &'a str,
) -> Vec<&'a str> {
    vec![
        "generate",
        "dataplane-token",
        "--name",
        name,
        "--mesh",
        mesh,
        "--type",
        kind,
        "--valid-for",
        valid_for,
    ]
}

pub(crate) fn token_via_api(
    addr: &str,
    kind: &str,
    name: &str,
    mesh: &str,
    valid_for: &str,
    admin_token: Option<&str>,
) -> Result<String, CliError> {
    let body = serde_json::json!({
        "name": name,
        "mesh": mesh,
        "type": kind,
        "validFor": valid_for,
    });
    // Token endpoint returns plain text (JWT), not JSON
    let token = exec::cp_api_text(
        addr,
        "/tokens/dataplane",
        exec::HttpMethod::Post,
        Some(&body),
        admin_token,
    )?;
    parse_token_response(&token)
        .map(|response| response.token)
        .map_err(|error| CliErrorKind::token_generation_failed(error.to_string()).into())
}
