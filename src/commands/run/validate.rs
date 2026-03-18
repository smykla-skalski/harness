use std::path::{Path, PathBuf};

use clap::Args;
use rayon::prelude::*;

use crate::commands::{CommandContext, Execute};
use crate::core_defs::shorten_path;
use crate::errors::{CliError, CliErrorKind};
use crate::exec::kubectl;
use crate::io::{read_text, write_text};
use crate::manifests::default_validation_output;

impl Execute for ValidateArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        validate(
            self.kubeconfig.as_deref(),
            &self.manifest,
            self.output.as_deref(),
        )
    }
}

/// Arguments for `harness validate`.
#[derive(Debug, Clone, Args)]
pub struct ValidateArgs {
    /// Use this kubeconfig instead of the tracked run cluster.
    #[arg(long)]
    pub kubeconfig: Option<String>,
    /// Manifest path.
    #[arg(long)]
    pub manifest: String,
    /// Validation log path; defaults beside the manifest artifact.
    #[arg(long)]
    pub output: Option<String>,
}

/// Validate a manifest against the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn validate(
    kubeconfig: Option<&str>,
    manifest: &str,
    output: Option<&str>,
) -> Result<i32, CliError> {
    let manifest_path = PathBuf::from(manifest);
    let output_path =
        output.map_or_else(|| default_validation_output(&manifest_path), PathBuf::from);

    // Detect platform from manifest content: universal uses type/name, K8s uses apiVersion/kind
    if is_universal_manifest(&manifest_path) {
        return validate_universal(&manifest_path, &output_path);
    }

    let kc = kubeconfig.map(PathBuf::from);
    validate_kubernetes(kc.as_deref(), manifest, &manifest_path, &output_path)
}

fn extract_resources(manifest: &Path) -> Result<Vec<(String, String)>, CliError> {
    use serde::Deserialize;

    let text = read_text(manifest)?;
    let mut resources = Vec::new();
    let mut parse_errors = Vec::new();
    for (index, document) in serde_yml::Deserializer::from_str(&text).enumerate() {
        let parsed: serde_yml::Value = match serde_yml::Value::deserialize(document) {
            Ok(v) => v,
            Err(e) => {
                parse_errors.push(format!("document {}: {e}", index + 1));
                continue;
            }
        };
        let kind = parsed
            .get("kind")
            .and_then(|v| v.as_str())
            .map(String::from);
        let api_version = parsed
            .get("apiVersion")
            .and_then(|v| v.as_str())
            .map(String::from);
        if let (Some(k), Some(av)) = (kind, api_version) {
            resources.push((k, av));
        }
    }
    if resources.is_empty() {
        let mut detail = manifest.display().to_string();
        if !parse_errors.is_empty() {
            detail = format!("{detail} (parse errors: {})", parse_errors.join("; "));
        }
        return Err(CliErrorKind::no_resource_kinds(detail).into());
    }
    Ok(resources)
}

fn validate_kubernetes(
    kc: Option<&Path>,
    manifest: &str,
    manifest_path: &Path,
    output_path: &Path,
) -> Result<i32, CliError> {
    let resources = extract_resources(manifest_path)?;

    // Write all "running" entries before spawning parallel explain calls.
    let mut log_lines: Vec<String> = resources
        .iter()
        .map(|(kind, api_version)| format!("explain {kind} ({api_version}): running"))
        .collect();
    write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;

    // Run kubectl explain for all resources in parallel.
    let explain_results: Vec<_> = resources
        .par_iter()
        .map(|(kind, api_version)| {
            kubectl(kc, &["explain", kind, "--api-version", api_version], &[0])
        })
        .collect();

    // Update log lines in declaration order, stopping on first failure.
    for (index, result) in explain_results.into_iter().enumerate() {
        let (kind, api_version) = &resources[index];
        let label = format!("{kind} ({api_version})");
        log_lines[index] = if result.is_ok() {
            format!("explain {label}: ok")
        } else {
            format!("explain {label}: failed")
        };
        result?;
    }
    write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;

    log_lines.push("dry-run: running".to_string());
    write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;

    kubectl(
        kc,
        &["apply", "--server-side", "--dry-run=server", "-f", manifest],
        &[0],
    )?;
    if let Some(last) = log_lines.last_mut() {
        *last = "dry-run: ok".to_string();
    }
    write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;

    let diff_result = kubectl(kc, &["diff", "-f", manifest], &[0, 1])?;
    log_lines.push(format!("diff exit code: {}", diff_result.returncode));
    write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;

    println!("{}", shorten_path(output_path));
    Ok(0)
}

fn is_universal_manifest(manifest_path: &Path) -> bool {
    let Ok(text) = read_text(manifest_path) else {
        return false;
    };
    // Universal manifests use `type:` instead of `apiVersion:`.
    // A file with any `apiVersion:` line is always Kubernetes (e.g. Service with type: LoadBalancer).
    !text.lines().any(|line| line.starts_with("apiVersion:"))
        && text.lines().any(|line| line.starts_with("type:"))
}

fn validate_universal(manifest_path: &Path, output_path: &Path) -> Result<i32, CliError> {
    use serde::Deserialize;

    let text = read_text(manifest_path)?;
    let mut log_lines: Vec<String> = Vec::new();
    let mut errors: Vec<String> = Vec::new();

    for document in serde_yml::Deserializer::from_str(&text) {
        let parsed: serde_yml::Value = match serde_yml::Value::deserialize(document) {
            Ok(v) => v,
            Err(e) => {
                errors.push(format!("YAML parse error: {e}"));
                continue;
            }
        };

        validate_universal_document(&parsed, &mut log_lines, &mut errors);
    }

    if !errors.is_empty() {
        log_lines.extend(errors.iter().map(|e| format!("ERROR: {e}")));
        write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;
        return Err(
            CliErrorKind::universal_validation_failed(manifest_path.display().to_string()).into(),
        );
    }

    write_text(output_path, &format!("{}\n", log_lines.join("\n")))?;
    println!("{}", shorten_path(output_path));
    Ok(0)
}

/// Validate a single universal YAML document for required fields.
fn validate_universal_document(
    parsed: &serde_yml::Value,
    log_lines: &mut Vec<String>,
    errors: &mut Vec<String>,
) {
    let resource_type = parsed.get("type").and_then(|v| v.as_str());
    let name = parsed.get("name").and_then(|v| v.as_str());
    let mesh = parsed.get("mesh").and_then(|v| v.as_str());

    let label = resource_type.unwrap_or("unknown");
    log_lines.push(format!("validate {label}: checking structure"));

    if resource_type.is_none() {
        errors.push(format!("missing 'type' field in resource: {label}"));
    }
    if name.is_none() {
        errors.push(format!("missing 'name' field in resource: {label}"));
    }
    // mesh is required for most types except ZoneIngress/ZoneEgress
    if mesh.is_none() && !matches!(resource_type, Some("ZoneIngress" | "ZoneEgress" | "Zone")) {
        errors.push(format!("missing 'mesh' field in resource: {label}"));
    }

    if errors.is_empty() {
        log_lines.push(format!("validate {label}: ok"));
    }
}
