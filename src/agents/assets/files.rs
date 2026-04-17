use std::collections::BTreeSet;
use std::fs::{Permissions, create_dir_all, metadata, remove_file, set_permissions};
use std::os::unix::fs::{PermissionsExt, symlink};
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
        for (link, target) in &output.symlinks {
            write_symlink(link, target)?;
        }
    }
    Ok(())
}

fn write_symlink(link: &Path, target: &Path) -> Result<(), CliError> {
    if let Some(parent) = link.parent() {
        create_dir_all(parent).map_err(|error| io_err(&error))?;
    }
    // Replace atomically if the link already exists but points elsewhere, or is a plain file.
    if link.exists() || link.symlink_metadata().is_ok() {
        let existing_target = std::fs::read_link(link).ok();
        if existing_target.as_deref() == Some(target) {
            return Ok(());
        }
        remove_file(link).map_err(|error| io_err(&error))?;
    }
    symlink(target, link).map_err(|error| io_err(&error))
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
    let mut drift: Vec<String> = output
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
        .collect();

    for (link, expected_target) in &output.symlinks {
        match std::fs::read_link(link) {
            Ok(actual_target) if actual_target == *expected_target => {}
            Ok(_) => drift.push(format!("symlink drift: {}", link.display())),
            Err(_) => drift.push(format!("missing symlink: {}", link.display())),
        }
    }

    drift
}

fn unexpected_output_drift(output: &PlannedOutput) -> Result<Vec<String>, CliError> {
    if !output.managed_root.exists() {
        return Ok(Vec::new());
    }

    let expected_files: BTreeSet<&Path> = output.files.keys().map(PathBuf::as_path).collect();
    let expected_symlinks: BTreeSet<&Path> = output.symlinks.keys().map(PathBuf::as_path).collect();
    let mut drift = Vec::new();
    for entry in WalkDir::new(&output.managed_root)
        .min_depth(1)
        .follow_links(false)
    {
        let entry = entry.map_err(|error| io_err(&error))?;
        if entry.file_type().is_dir() {
            continue;
        }
        let path = entry.path();
        if !expected_files.contains(path) && !expected_symlinks.contains(path) {
            drift.push(format!("unexpected: {}", path.display()));
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
