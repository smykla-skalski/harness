use std::path::Path;

use crate::cli::EnvoyCommand;
use crate::errors::{CliError, CliErrorKind};
use crate::io::read_text;

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
