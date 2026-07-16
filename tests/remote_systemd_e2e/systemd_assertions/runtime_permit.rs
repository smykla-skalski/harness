use std::ffi::OsStr;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::str;

use super::{persistent_inhibitor_path, root_path_matches, runtime_permit_directory, sudo};

const PERMIT_FILE: &str = "90-harness-inhibit.conf";
const PERMIT_PREFIX: &str = "[Unit]\nConditionPathExists=";
const TOKEN_PREFIX: &str = ".harness-start-permit-";
const TOKEN_SUFFIX: &str = ".token";
const MINIMUM_PERMIT_FD: i32 = 512;

pub(super) fn assert_live_runtime_permit(
    unit: &str,
    coordinator_pid: u32,
    drop_in_paths: &str,
) -> Result<(), String> {
    let persistent = persistent_inhibitor_path(unit);
    require_regular_file(&persistent, "persistent systemd inhibitor")?;
    let permit = runtime_permit_path(unit);
    if drop_in_paths != permit.to_string_lossy() {
        return Err(format!(
            "systemd loaded {drop_in_paths:?} at the live-permit boundary, expected {}",
            permit.display()
        ));
    }
    require_regular_file(&permit, "runtime systemd start permit")?;
    let condition = read_condition_path(&permit)?;
    validate_condition_path(&condition, coordinator_pid)?;
    if root_path_matches("-e", &condition)? {
        Ok(())
    } else {
        Err(format!(
            "runtime systemd start permit condition is not live: {}",
            condition.display()
        ))
    }
}

pub(super) fn assert_cached_runtime_permit_is_dead(
    unit: &str,
    drop_in_paths: &str,
) -> Result<(), String> {
    let persistent = persistent_inhibitor_path(unit);
    require_regular_file(&persistent, "persistent systemd inhibitor")?;
    let permit = runtime_permit_path(unit);
    if drop_in_paths != permit.to_string_lossy() {
        return Err(format!(
            "systemd did not retain the cached runtime drop-in after removal: observed {drop_in_paths:?}, expected {}",
            permit.display()
        ));
    }
    assert_runtime_permit_artifacts_absent(unit)
}

pub(super) fn assert_runtime_permit_artifacts_absent(unit: &str) -> Result<(), String> {
    let permit = runtime_permit_path(unit);
    if root_path_matches("-e", &permit)? || root_path_matches("-L", &permit)? {
        return Err(format!(
            "runtime systemd start permit remains installed: {}",
            permit.display()
        ));
    }
    let directory = runtime_permit_directory(unit);
    let metadata = match fs::symlink_metadata(&directory) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(format!(
                "inspect runtime systemd permit directory {}: {error}",
                directory.display()
            ));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "runtime systemd permit directory is not a real directory: {}",
            directory.display()
        ));
    }
    for entry in fs::read_dir(&directory).map_err(|error| {
        format!(
            "inspect runtime systemd permit directory {}: {error}",
            directory.display()
        )
    })? {
        let entry = entry.map_err(|error| {
            format!(
                "inspect runtime systemd permit entry in {}: {error}",
                directory.display()
            )
        })?;
        if is_token_directory_name(&entry.file_name()) {
            return Err(format!(
                "runtime systemd permit token remains installed: {}",
                entry.path().display()
            ));
        }
    }
    Ok(())
}

fn runtime_permit_path(unit: &str) -> PathBuf {
    runtime_permit_directory(unit).join(PERMIT_FILE)
}

fn require_regular_file(path: &Path, label: &str) -> Result<(), String> {
    if root_path_matches("-f", path)? && !root_path_matches("-L", path)? {
        Ok(())
    } else {
        Err(format!("{label} is not a regular file: {}", path.display()))
    }
}

fn read_condition_path(path: &Path) -> Result<PathBuf, String> {
    let output = sudo([OsStr::new("cat"), path.as_os_str()])
        .output()
        .map_err(|error| format!("read runtime systemd permit {}: {error}", path.display()))?;
    if !output.status.success() {
        return Err(format!(
            "read runtime systemd permit {} exited with {}; stderr={}",
            path.display(),
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let contents = str::from_utf8(&output.stdout)
        .map_err(|error| format!("decode runtime systemd permit: {error}"))?;
    let condition = contents
        .strip_prefix(PERMIT_PREFIX)
        .and_then(|value| value.strip_suffix('\n'))
        .ok_or_else(|| "runtime systemd permit has unexpected contents".to_string())?;
    Ok(PathBuf::from(condition))
}

fn validate_condition_path(path: &Path, coordinator_pid: u32) -> Result<(), String> {
    let prefix = PathBuf::from(format!("/proc/{coordinator_pid}/fd"));
    let relative = path.strip_prefix(&prefix).map_err(|error| {
        format!(
            "runtime permit condition {} is not owned by coordinator {coordinator_pid}: {error}",
            path.display()
        )
    })?;
    let mut components = relative.components();
    let descriptor = components
        .next()
        .and_then(|component| component.as_os_str().to_str())
        .and_then(|value| value.parse::<i32>().ok());
    let token = components
        .next()
        .map(|component| component.as_os_str())
        .filter(|name| is_token_file_name(name));
    if descriptor.is_some_and(|value| value >= MINIMUM_PERMIT_FD)
        && token.is_some()
        && components.next().is_none()
    {
        Ok(())
    } else {
        Err(format!(
            "runtime permit condition has an invalid descriptor or token: {}",
            path.display()
        ))
    }
}

fn is_token_directory_name(name: &OsStr) -> bool {
    name.to_str()
        .and_then(|name| name.strip_prefix(TOKEN_PREFIX))
        .is_some_and(is_simple_uuid)
}

fn is_token_file_name(name: &OsStr) -> bool {
    name.to_str()
        .and_then(|name| name.strip_prefix(TOKEN_PREFIX))
        .and_then(|identity| identity.strip_suffix(TOKEN_SUFFIX))
        .is_some_and(is_simple_uuid)
}

fn is_simple_uuid(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}
