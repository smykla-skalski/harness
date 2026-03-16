use std::path::{Path, PathBuf};

use chrono::Utc;
use clap::Args;

use crate::audit_log::write_run_status_with_audit;
use crate::cluster::Platform;
use crate::commands::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::context::RunContext;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec;
use crate::exec::kubectl;
use crate::io::{validate_safe_segment, write_text};
use crate::workflow::runner::read_runner_state;

use super::shared::detect_platform;

/// Arguments for `harness capture`.
#[derive(Debug, Clone, Args)]
pub struct CaptureArgs {
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Label for the saved artifact filename.
    #[arg(long)]
    pub label: String,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

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

    let rel = ctx.layout.relative_path(&capture_path);

    if let Some(mut status) = ctx.status {
        status.last_state_capture = Some(rel.clone());
        let runner_state = read_runner_state(&ctx.layout.run_dir())?;
        write_run_status_with_audit(
            &ctx.layout.run_dir(),
            &status,
            runner_state.as_ref(),
            None,
            None,
        )?;
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

    // Parse newline-delimited JSON rows from docker ps into a JSON array
    let container_rows: Vec<serde_json::Value> = containers
        .stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();

    // Collect dataplane state from CP if available
    let admin_token = spec.admin_token();
    let (dataplanes, dataplanes_error) = if let Some(url) = spec.primary_api_url() {
        match exec::cp_api_json(
            &url,
            "/meshes/default/dataplanes",
            exec::HttpMethod::Get,
            None,
            admin_token,
        ) {
            Ok(val) => (val, serde_json::Value::Null),
            Err(e) => {
                eprintln!("warning: CP API dataplanes query failed: {e}");
                (
                    serde_json::json!({"items": []}),
                    serde_json::Value::String(e.to_string()),
                )
            }
        }
    } else {
        (serde_json::json!({"items": []}), serde_json::Value::Null)
    };

    let capture = serde_json::json!({
        "platform": "universal",
        "containers": container_rows,
        "dataplanes": dataplanes,
        "dataplanes_error": dataplanes_error,
    });
    let json_str = serde_json::to_string_pretty(&capture)
        .map_err(|e| CliErrorKind::serialize(cow!("capture: {e}")))?;
    write_text(capture_path, &json_str)?;
    Ok(())
}
