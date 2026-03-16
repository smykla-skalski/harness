use serde_json::json;

use crate::cli::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

/// Mask an admin token: show first 4 and last 4 chars.
fn mask_token(token: &str) -> String {
    if token.len() <= 8 {
        return "****".to_string();
    }
    format!("{}...{}", &token[..4], &token[token.len() - 4..])
}

/// Show cluster state as structured JSON.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn status(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;
    let spec = ctx
        .cluster
        .as_ref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;

    let members: Vec<serde_json::Value> = spec
        .members
        .iter()
        .map(|m| {
            json!({
                "name": m.name,
                "role": m.role,
                "container_ip": m.container_ip,
                "cp_api_port": m.cp_api_port,
                "xds_port": m.xds_port,
            })
        })
        .collect();

    // List running service containers (non-fatal)
    let services = exec::docker(
        &[
            "ps",
            "--filter",
            "label=io.harness.service=true",
            "--format",
            "{{.Names}}\t{{.Status}}",
        ],
        &[0, 1],
    )
    .map_err(|e| {
        eprintln!("warning: docker ps failed: {e}");
        e
    })
    .ok()
    .map(|r| {
        r.stdout
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| {
                let parts: Vec<&str> = l.splitn(2, '\t').collect();
                json!({
                    "name": parts.first().unwrap_or(&""),
                    "status": parts.get(1).unwrap_or(&""),
                })
            })
            .collect::<Vec<_>>()
    })
    .unwrap_or_default();

    // Registered dataplanes from CP API (non-fatal)
    let dataplanes = if let Some(url) = spec.primary_api_url() {
        exec::cp_api_json(
            &url,
            "/meshes/default/dataplanes",
            exec::HttpMethod::Get,
            None,
            spec.admin_token(),
        )
        .map_err(|e| {
            eprintln!("warning: CP API dataplanes query failed: {e}");
            e
        })
        .ok()
    } else {
        None
    };

    let masked_token = spec
        .admin_token
        .as_deref()
        .map(mask_token)
        .unwrap_or_default();

    let output = json!({
        "platform": spec.platform,
        "mode": spec.mode,
        "cp_address": spec.primary_api_url(),
        "admin_token": masked_token,
        "store_type": spec.store_type,
        "docker_network": spec.docker_network,
        "cp_image": spec.cp_image,
        "members": members,
        "services": services,
        "dataplanes": dataplanes,
    });

    let pretty = serde_json::to_string_pretty(&output)
        .map_err(|e| CliErrorKind::serialize(format!("status: {e}")))?;
    println!("{pretty}");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mask_token_short() {
        assert_eq!(mask_token("abc"), "****");
    }

    #[test]
    fn mask_token_normal() {
        assert_eq!(mask_token("abcdefghijklmnop"), "abcd...mnop");
    }
}
