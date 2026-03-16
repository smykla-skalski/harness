use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::commands::{resolve_admin_token, resolve_cp_addr, resolve_run_context};
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

use super::kumactl::find_kumactl_binary;

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
    let ctx = resolve_run_context(run_dir_args)?;
    let addr = if let Some(a) = cp_addr {
        a.to_string()
    } else {
        resolve_cp_addr(&ctx)?
    };
    let admin_token = resolve_admin_token(&ctx)?;

    // Try REST API first
    match token_via_api(&addr, kind, name, mesh, valid_for, admin_token.as_deref()) {
        Ok(tok) => {
            println!("{tok}");
            return Ok(0);
        }
        Err(api_err) => {
            eprintln!("token: API failed ({api_err}), trying kumactl");
        }
    }

    // Fallback to kumactl
    let root = PathBuf::from(&ctx.metadata.repo_root);
    let binary = find_kumactl_binary(&root)?;

    let mut args = vec!["generate", "dataplane-token"];
    args.extend_from_slice(&["--name", name]);
    args.extend_from_slice(&["--mesh", mesh]);
    args.extend_from_slice(&["--type", kind]);
    args.extend_from_slice(&["--valid-for", valid_for]);

    let result = exec::kumactl_run(&binary, &addr, &args, &[0])?;
    let tok = result.stdout.trim();
    println!("{tok}");
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
    let trimmed = token.trim().to_string();
    if trimmed.is_empty() {
        return Err(CliErrorKind::token_generation_failed("empty response").into());
    }
    Ok(trimmed)
}
