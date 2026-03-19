use std::borrow::Cow;
use std::path::PathBuf;

use clap::Args;

use tracing::warn;

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

    // Try REST API first
    match token_via_api(addr.as_ref(), kind, name, mesh, valid_for, admin_token) {
        Ok(tok) => {
            println!("{tok}");
            return Ok(0);
        }
        Err(api_err) => {
            warn!(%api_err, "token API failed, trying kumactl");
        }
    }

    // Fallback to kumactl
    let root = PathBuf::from(&run.metadata().repo_root);
    let binary = find_kumactl_binary(&root)?;

    let mut args = vec!["generate", "dataplane-token"];
    args.extend_from_slice(&["--name", name]);
    args.extend_from_slice(&["--mesh", mesh]);
    args.extend_from_slice(&["--type", kind]);
    args.extend_from_slice(&["--valid-for", valid_for]);

    let result = exec::kumactl_run(&binary, addr.as_ref(), &args, &[0])?;
    let token = parse_token_response(&result.stdout)
        .map_err(|error| CliErrorKind::token_generation_failed(error.to_string()))?;
    println!("{}", token.token);
    Ok(0)
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
