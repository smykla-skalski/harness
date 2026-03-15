use std::path::Path;

use crate::cli::EnvoyCommand;
use crate::errors::{CliError, CliErrorKind};
use crate::io::read_text;

/// Envoy admin operations.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(cmd: &EnvoyCommand) -> Result<i32, CliError> {
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
                let payload: serde_json::Value = serde_json::from_str(&text).map_err(|_| {
                    CliError::from(CliErrorKind::InvalidJson {
                        path: file_path.clone().into(),
                    })
                })?;
                match find_route(&payload, route_match) {
                    Some(route) => {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&route).unwrap_or_default()
                        );
                        Ok(0)
                    }
                    None => Err(CliErrorKind::RouteNotFound {
                        route_match: route_match.clone().into(),
                    }
                    .into()),
                }
            } else {
                Err(CliErrorKind::EnvoyCaptureArgsRequired {
                    fields: "--file or --namespace/--workload".into(),
                }
                .into())
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
                Err(CliErrorKind::EnvoyCaptureArgsRequired {
                    fields: "--file or --namespace/--workload".into(),
                }
                .into())
            }
        }
    }
}

fn find_route<'a>(
    payload: &'a serde_json::Value,
    match_path: &str,
) -> Option<&'a serde_json::Value> {
    let configs = payload.get("configs")?.as_array()?;
    for config in configs {
        let Some(config_obj) = config.as_object() else {
            continue;
        };
        for key in &["dynamic_route_configs", "static_route_configs"] {
            if let Some(entries) = config_obj.get(*key).and_then(|v| v.as_array()) {
                for entry in entries {
                    if let Some(route_config) =
                        entry.get("route_config").and_then(|v| v.as_object())
                        && let Some(vhosts) =
                            route_config.get("virtual_hosts").and_then(|v| v.as_array())
                    {
                        for vh in vhosts {
                            if let Some(routes) = vh.get("routes").and_then(|v| v.as_array()) {
                                for route in routes {
                                    if let Some(m) = route.get("match").and_then(|v| v.as_object())
                                    {
                                        let path = m.get("path").and_then(|v| v.as_str());
                                        let prefix = m.get("prefix").and_then(|v| v.as_str());
                                        if path == Some(match_path) || prefix == Some(match_path) {
                                            return Some(route);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    None
}
