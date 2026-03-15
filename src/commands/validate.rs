use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::exec::kubectl;
use crate::io::{read_text, write_text};
use crate::manifests::default_validation_output;

fn extract_resources(manifest: &Path) -> Result<Vec<(String, String)>, CliError> {
    let text = read_text(manifest)?;
    let normalized = format!("\n{text}");
    let mut resources = Vec::new();
    for doc in normalized.split("\n---\n") {
        let mut api_version: Option<String> = None;
        let mut kind: Option<String> = None;
        for line in doc.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty()
                || trimmed.starts_with('#')
                || line.starts_with(' ')
                || line.starts_with('\t')
            {
                continue;
            }
            if let Some((key, value)) = trimmed.split_once(':') {
                let v = value
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .to_string();
                match key {
                    "apiVersion" => api_version = Some(v),
                    "kind" => kind = Some(v),
                    _ => {}
                }
            }
            if api_version.is_some() && kind.is_some() {
                resources.push((kind.take().unwrap(), api_version.take().unwrap()));
                break;
            }
        }
    }
    if resources.is_empty() {
        return Err(CliErrorKind::NoResourceKinds {
            manifest: manifest.display().to_string().into(),
        }
        .into());
    }
    Ok(resources)
}

/// Validate a manifest against the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    kubeconfig: Option<&str>,
    manifest: &str,
    output: Option<&str>,
) -> Result<i32, CliError> {
    let manifest_path = PathBuf::from(manifest);
    let kc = kubeconfig.map(PathBuf::from);
    let output_path =
        output.map_or_else(|| default_validation_output(&manifest_path), PathBuf::from);

    let resources = extract_resources(&manifest_path)?;
    let mut log_lines: Vec<String> = Vec::new();

    for (kind, api_version) in &resources {
        let label = format!("{kind} ({api_version})");
        log_lines.push(format!("explain {label}: running"));
        write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

        kubectl(
            kc.as_deref(),
            &["explain", kind, "--api-version", api_version],
            &[0],
        )?;
        if let Some(last) = log_lines.last_mut() {
            *last = format!("explain {label}: ok");
        }
        write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;
    }

    log_lines.push("dry-run: running".to_string());
    write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

    kubectl(
        kc.as_deref(),
        &["apply", "--server-side", "--dry-run=server", "-f", manifest],
        &[0],
    )?;
    if let Some(last) = log_lines.last_mut() {
        *last = "dry-run: ok".to_string();
    }
    write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

    let diff = kubectl(kc.as_deref(), &["diff", "-f", manifest], &[0, 1])?;
    log_lines.push(format!("diff exit code: {}", diff.returncode));
    write_text(&output_path, &format!("{}\n", log_lines.join("\n")))?;

    println!("{}", output_path.display());
    Ok(0)
}
