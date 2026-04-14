use std::collections::BTreeSet;
use std::fs::{Permissions, metadata, set_permissions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use walkdir::WalkDir;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_text};

use super::model::PlannedOutput;

pub(super) fn managed_root_for_path(repo_root: &Path, path: &Path) -> Result<PathBuf, CliError> {
    for managed in [
        ".claude/skills",
        ".claude/plugins",
        ".agents/skills",
        ".agents/plugins",
        ".gemini/commands",
        ".github/hooks",
        ".vibe/skills",
        ".vibe/plugins",
        ".opencode/skills",
        ".opencode/plugins",
        "plugins",
    ] {
        let root = repo_root.join(managed);
        if path.starts_with(&root) {
            return Ok(root);
        }
    }
    Err(CliErrorKind::usage_error(format!(
        "generated path {} is outside managed roots",
        path.display()
    ))
    .into())
}

pub(super) fn write_outputs(planned: &[PlannedOutput]) -> Result<(), CliError> {
    for output in planned {
        let _ = &output.managed_root;
        for (path, content) in &output.files {
            write_text(path, content)?;
            if is_executable_generated_output(path) {
                set_permissions(path, Permissions::from_mode(0o755))
                    .map_err(|error| io_err(&error))?;
            }
        }
    }
    Ok(())
}

pub(super) fn ensure_outputs_match(planned: &[PlannedOutput]) -> Result<(), CliError> {
    let mut drift = Vec::new();
    for output in planned {
        drift.extend(expected_output_drift(output));
        drift.extend(unexpected_output_drift(output)?);
    }
    if drift.is_empty() {
        Ok(())
    } else {
        Err(CliErrorKind::usage_error(format!(
            "generated agent assets are out of date:\n{}",
            drift.join("\n")
        ))
        .into())
    }
}

fn expected_output_drift(output: &PlannedOutput) -> Vec<String> {
    output
        .files
        .iter()
        .filter_map(|(path, expected)| match read_text(path) {
            Ok(actual) if actual == *expected => {
                if is_executable_generated_output(path) && !path_is_executable(path) {
                    Some(format!("mode drift: {}", path.display()))
                } else {
                    None
                }
            }
            Ok(_) => Some(format!("drift: {}", path.display())),
            Err(_) => Some(format!("missing: {}", path.display())),
        })
        .collect()
}

fn unexpected_output_drift(output: &PlannedOutput) -> Result<Vec<String>, CliError> {
    if !output.managed_root.exists() {
        return Ok(Vec::new());
    }

    let expected_paths: BTreeSet<&Path> = output.files.keys().map(PathBuf::as_path).collect();
    let mut drift = Vec::new();
    for entry in WalkDir::new(&output.managed_root).min_depth(1) {
        let entry = entry.map_err(|error| io_err(&error))?;
        if entry.file_type().is_dir() {
            continue;
        }
        if !expected_paths.contains(entry.path()) {
            drift.push(format!("unexpected: {}", entry.path().display()));
        }
    }
    Ok(drift)
}

fn is_executable_generated_output(path: &Path) -> bool {
    path.ends_with(Path::new(".claude/plugins/suite/harness"))
}

fn path_is_executable(path: &Path) -> bool {
    metadata(path).is_ok_and(|meta| meta.permissions().mode() & 0o111 != 0)
}

pub(super) fn io_err(error: &impl ToString) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
}
