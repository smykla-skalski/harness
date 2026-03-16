use std::path::Path;

use clap::{Args, Subcommand};

use crate::commands::RunDirArgs;
use crate::errors::{CliError, CliErrorKind};
use crate::io::read_text;

/// Envoy admin operations.
#[non_exhaustive]
#[derive(Debug, Clone, Subcommand)]
pub enum EnvoyCommand {
    /// Capture a live Envoy admin payload.
    Capture {
        /// Optional phase tag for the command artifact name.
        #[arg(long)]
        phase: Option<String>,
        /// Artifact label for the captured payload.
        #[arg(long)]
        label: String,
        /// Tracked cluster member name for multi-zone captures.
        #[arg(long)]
        cluster: Option<String>,
        /// Namespace of the workload to exec into.
        #[arg(long)]
        namespace: String,
        /// kubectl exec target (e.g. deploy/demo-client).
        #[arg(long)]
        workload: String,
        /// Container name inside the workload.
        #[arg(long, default_value = "kuma-sidecar")]
        container: String,
        /// Envoy admin path to fetch.
        #[arg(long, default_value = "/config_dump")]
        admin_path: String,
        /// Envoy admin host inside the container.
        #[arg(long, default_value = "127.0.0.1")]
        admin_host: String,
        /// Envoy admin port inside the container.
        #[arg(long, default_value_t = 9901)]
        admin_port: u16,
        /// Artifact format hint.
        #[arg(long, default_value = "auto")]
        format: String,
        /// Print only config entries whose @type contains this text.
        #[arg(long)]
        type_contains: Option<String>,
        /// Print only lines containing this text after type filtering.
        #[arg(long)]
        grep: Option<String>,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Print a matching route from an Envoy config dump.
    RouteBody {
        /// Envoy config dump JSON file; omit to capture live.
        #[arg(long)]
        file: Option<String>,
        /// Exact route path or prefix to match.
        #[arg(long, name = "match")]
        route_match: String,
        /// Optional phase tag.
        #[arg(long)]
        phase: Option<String>,
        /// Artifact label.
        #[arg(long)]
        label: Option<String>,
        /// Tracked cluster member name.
        #[arg(long)]
        cluster: Option<String>,
        /// Namespace of the workload.
        #[arg(long)]
        namespace: Option<String>,
        /// kubectl exec target.
        #[arg(long)]
        workload: Option<String>,
        /// Container name.
        #[arg(long, default_value = "kuma-sidecar")]
        container: String,
        /// Envoy admin path.
        #[arg(long, default_value = "/config_dump")]
        admin_path: String,
        /// Envoy admin host.
        #[arg(long, default_value = "127.0.0.1")]
        admin_host: String,
        /// Envoy admin port.
        #[arg(long, default_value_t = 9901)]
        admin_port: u16,
        /// Artifact format hint.
        #[arg(long, default_value = "auto")]
        format: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
    /// Print the bootstrap payload from an Envoy config dump.
    Bootstrap {
        /// Bootstrap JSON file; omit to capture live.
        #[arg(long)]
        file: Option<String>,
        /// Substring filter for rendered bootstrap output.
        #[arg(long)]
        grep: Option<String>,
        /// Optional phase tag.
        #[arg(long)]
        phase: Option<String>,
        /// Artifact label.
        #[arg(long)]
        label: Option<String>,
        /// Tracked cluster member name.
        #[arg(long)]
        cluster: Option<String>,
        /// Namespace of the workload.
        #[arg(long)]
        namespace: Option<String>,
        /// kubectl exec target.
        #[arg(long)]
        workload: Option<String>,
        /// Container name.
        #[arg(long, default_value = "kuma-sidecar")]
        container: String,
        /// Envoy admin path.
        #[arg(long, default_value = "/config_dump")]
        admin_path: String,
        /// Envoy admin host.
        #[arg(long, default_value = "127.0.0.1")]
        admin_host: String,
        /// Envoy admin port.
        #[arg(long, default_value_t = 9901)]
        admin_port: u16,
        /// Artifact format hint.
        #[arg(long, default_value = "auto")]
        format: String,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
}

/// Arguments for `harness envoy`.
#[derive(Debug, Clone, Args)]
pub struct EnvoyArgs {
    /// Envoy subcommand.
    #[command(subcommand)]
    pub cmd: EnvoyCommand,
}

/// Envoy admin operations.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn envoy(cmd: &EnvoyCommand) -> Result<i32, CliError> {
    match cmd {
        EnvoyCommand::Capture {
            phase: _,
            label,
            cluster: _,
            namespace,
            workload,
            container: _,
            admin_path: _,
            admin_host: _,
            admin_port: _,
            format: _,
            type_contains: _,
            grep: _,
            run_dir: _,
        } => {
            // Live capture requires a running cluster. Print the artifact path.
            println!("envoy capture: label={label}, namespace={namespace}, workload={workload}");
            Ok(0)
        }
        EnvoyCommand::RouteBody {
            file, route_match, ..
        } => {
            if let Some(file_path) = file {
                let text = read_text(Path::new(file_path))?;
                let payload: serde_json::Value = serde_json::from_str(&text)
                    .map_err(|_| CliError::from(CliErrorKind::invalid_json(file_path.clone())))?;
                match find_route(&payload, route_match) {
                    Some(route) => {
                        let body = serde_json::to_string_pretty(route).map_err(|e| {
                            CliError::from(CliErrorKind::serialize(format!("route body: {e}")))
                        })?;
                        println!("{body}");
                        Ok(0)
                    }
                    None => Err(CliErrorKind::route_not_found(route_match.clone()).into()),
                }
            } else {
                Err(
                    CliErrorKind::envoy_capture_args_required("--file or --namespace/--workload")
                        .into(),
                )
            }
        }
        EnvoyCommand::Bootstrap { file, grep, .. } => {
            if let Some(file_path) = file {
                let text = read_text(Path::new(file_path))?;
                let output = if let Some(needle) = grep {
                    text.lines()
                        .filter(|l| l.contains(needle.as_str()))
                        .collect::<Vec<_>>()
                        .join("\n")
                } else {
                    text
                };
                println!("{output}");
                Ok(0)
            } else {
                Err(
                    CliErrorKind::envoy_capture_args_required("--file or --namespace/--workload")
                        .into(),
                )
            }
        }
    }
}

fn find_route<'a>(
    payload: &'a serde_json::Value,
    match_path: &str,
) -> Option<&'a serde_json::Value> {
    let configs = payload.get("configs")?.as_array()?;
    let keys = ["dynamic_route_configs", "static_route_configs"];

    configs
        .iter()
        .filter_map(|c| c.as_object())
        .flat_map(|obj| keys.iter().filter_map(move |k| obj.get(*k)?.as_array()))
        .flatten()
        .filter_map(|entry| entry.get("route_config")?.as_object())
        .filter_map(|rc| rc.get("virtual_hosts")?.as_array())
        .flatten()
        .filter_map(|vh| vh.get("routes")?.as_array())
        .flatten()
        .find(|route| {
            route
                .get("match")
                .and_then(|v| v.as_object())
                .is_some_and(|m| {
                    m.get("path").and_then(|v| v.as_str()) == Some(match_path)
                        || m.get("prefix").and_then(|v| v.as_str()) == Some(match_path)
                })
        })
}
