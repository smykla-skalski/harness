use std::path::Path;

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
use crate::runtime::ControlPlaneAccess;
use crate::workflow::runner::read_runner_state;

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
    let runtime = ctx.cluster_runtime()?;

    let timestamp = Utc::now().format("%Y-%m-%dT%H%M%S.%6fZ").to_string();
    let capture_path = ctx
        .layout
        .state_dir()
        .join(format!("{label}-{timestamp}.json"));

    match runtime.platform() {
        Platform::Kubernetes => {
            let resolved = runtime.resolve_kubeconfig(kubeconfig, None)?;
            capture_kubernetes(Some(&resolved), &capture_path)?;
        }
        Platform::Universal => {
            let access = runtime.control_plane_access()?;
            capture_universal(&ctx, access, &capture_path)?;
        }
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

fn capture_kubernetes(kubeconfig: Option<&Path>, capture_path: &Path) -> Result<(), CliError> {
    let result = kubectl(
        kubeconfig,
        &["get", "pods", "--all-namespaces", "-o", "json"],
        &[0],
    )?;
    write_text(capture_path, &result.stdout)?;
    Ok(())
}

fn capture_universal(
    ctx: &RunContext,
    access: &ControlPlaneAccess,
    capture_path: &Path,
) -> Result<(), CliError> {
    let network = ctx
        .cluster_runtime()
        .ok()
        .and_then(|runtime| runtime.docker_network().ok().map(ToString::to_string))
        .unwrap_or_else(|| "harness-default".to_string());

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
    let (dataplanes, dataplanes_error) = match exec::cp_api_json(
        &access.addr,
        "/meshes/default/dataplanes",
        exec::HttpMethod::Get,
        None,
        access.admin_token.as_deref(),
    ) {
        Ok(val) => (val, serde_json::Value::Null),
        Err(e) => {
            eprintln!("warning: CP API dataplanes query failed: {e}");
            (
                serde_json::json!({"items": []}),
                serde_json::Value::String(e.to_string()),
            )
        }
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
