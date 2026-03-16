use std::fs;
use std::path::{Path, PathBuf};

use chrono::Utc;

use crate::cli::RunDirArgs;
use crate::cluster::Platform;
use crate::commands::resolve_run_context;
use crate::context::RunContext;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec;
use crate::exec::kubectl;
use crate::io::{validate_safe_segment, write_text};

use super::shared::detect_platform;

/// Capture cluster pod state for a run.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capture(
    kubeconfig: Option<&str>,
    label: &str,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    validate_safe_segment(label)?;
    let ctx = resolve_run_context(run_dir_args)?;
    let platform = detect_platform(&ctx);

    let timestamp = Utc::now().format("%Y-%m-%dT%H%M%S.%6fZ").to_string();
    let capture_path = ctx
        .layout
        .state_dir()
        .join(format!("{label}-{timestamp}.json"));

    match platform {
        Platform::Kubernetes => capture_kubernetes(&ctx, kubeconfig, &capture_path)?,
        Platform::Universal => capture_universal(&ctx, &capture_path)?,
    }

    let rel = capture_path.strip_prefix(ctx.layout.run_dir()).map_or_else(
        |_| capture_path.display().to_string(),
        |p| p.display().to_string(),
    );

    if let Some(mut status) = ctx.status {
        status.last_state_capture = Some(rel.clone());
        let status_json = serde_json::to_string_pretty(&status)
            .map_err(|e| CliErrorKind::serialize(cow!("capture status update: {e}")))?;
        fs::write(ctx.layout.status_path(), format!("{status_json}\n"))?;
    }

    println!("{rel}");
    Ok(0)
}

fn capture_kubernetes(
    ctx: &RunContext,
    kubeconfig: Option<&str>,
    capture_path: &Path,
) -> Result<(), CliError> {
    let kc = kubeconfig.map(PathBuf::from).or_else(|| {
        ctx.cluster
            .as_ref()
            .map(|c| PathBuf::from(c.primary_kubeconfig()))
    });

    let result = kubectl(
        kc.as_deref(),
        &["get", "pods", "--all-namespaces", "-o", "json"],
        &[0],
    )?;
    write_text(capture_path, &result.stdout)?;
    Ok(())
}

fn capture_universal(ctx: &RunContext, capture_path: &Path) -> Result<(), CliError> {
    let spec = ctx
        .cluster
        .as_ref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;
    let network = spec.docker_network.as_deref().unwrap_or("harness-default");

    // Collect container state
    let containers = exec::docker(
        &[
            "ps",
            "--filter",
            &format!("network={network}"),
            "--format",
            "{{json .}}",
        ],
        &[0],
    )?;

    // Collect dataplane state from CP if available
    let admin_token = spec.admin_token();
    let dataplanes = if let Some(url) = spec.primary_api_url() {
        exec::cp_api_json(
            &url,
            "/meshes/default/dataplanes",
            exec::HttpMethod::Get,
            None,
            admin_token,
        )
        .map_err(|e| {
            eprintln!("warning: CP API dataplanes query failed: {e}");
            e
        })
        .ok()
        .unwrap_or(serde_json::json!({"items": []}))
    } else {
        serde_json::json!({"items": []})
    };

    let capture = serde_json::json!({
        "platform": "universal",
        "containers": containers.stdout.trim(),
        "dataplanes": dataplanes,
    });
    let json_str = serde_json::to_string_pretty(&capture)
        .map_err(|e| CliErrorKind::serialize(cow!("capture: {e}")))?;
    write_text(capture_path, &json_str)?;
    Ok(())
}
