use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

#[path = "systemd_assertions/claim_registry.rs"]
mod claim_registry;
#[path = "systemd_assertions/runtime_permit.rs"]
mod runtime_permit;

use runtime_permit::assert_runtime_permit_artifacts_absent;

pub(super) fn assert_binary_claim_absent(unit: &str) -> Result<(), String> {
    claim_registry::assert_binary_claim_absent(unit)
}

pub(super) fn assert_cached_runtime_permit_is_dead(
    unit: &str,
    drop_in_paths: &str,
) -> Result<(), String> {
    runtime_permit::assert_cached_runtime_permit_is_dead(unit, drop_in_paths)
}

pub(super) fn assert_live_runtime_permit(
    unit: &str,
    coordinator_pid: u32,
    drop_in_paths: &str,
) -> Result<(), String> {
    runtime_permit::assert_live_runtime_permit(unit, coordinator_pid, drop_in_paths)
}

pub(super) fn assert_uninstalled(units: &[&str], root_owned_paths: &[&Path]) -> Result<(), String> {
    for unit in units {
        let load_state = systemd_property(unit, "LoadState")?;
        if load_state != "not-found" {
            return Err(format!(
                "systemd cleanup left {unit} loaded with LoadState={load_state}"
            ));
        }
        assert_systemd_state("is-active", unit, &["inactive", "unknown"])?;
        assert_systemd_state(
            "is-enabled",
            unit,
            &["disabled", "not-found", "static", "transient"],
        )?;
    }
    for path in root_owned_paths {
        if root_path_matches("-e", path)? || root_path_matches("-L", path)? {
            return Err(format!("systemd cleanup left {} behind", path.display()));
        }
    }
    Ok(())
}

fn systemd_property(unit: &str, property: &str) -> Result<String, String> {
    let output = Command::new("systemctl")
        .args(["show", "--value", "--property", property, unit])
        .output()
        .map_err(|error| format!("inspect {unit} property {property}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "inspect {unit} property {property} exited with {}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub(super) fn assert_private_root_directory(path: &Path, label: &str) -> Result<(), String> {
    if !root_path_matches("-d", path)? || root_path_matches("-L", path)? {
        return Err(format!(
            "{label} is not a regular directory: {}",
            path.display()
        ));
    }
    let output = sudo([
        OsStr::new("stat"),
        OsStr::new("-c"),
        OsStr::new("%u:%g:%a"),
        path.as_os_str(),
    ])
    .output()
    .map_err(|error| format!("inspect {label} ownership: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "inspect {label} ownership exited with {}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let observation = String::from_utf8_lossy(&output.stdout);
    let mut fields = observation.trim().split(':');
    let uid = parse_decimal(fields.next(), label, "uid")?;
    let gid = parse_decimal(fields.next(), label, "gid")?;
    let mode = fields
        .next()
        .ok_or_else(|| format!("{label} stat omitted mode: {observation}"))
        .and_then(|value| {
            u32::from_str_radix(value, 8)
                .map_err(|error| format!("parse {label} mode {value:?}: {error}"))
        })?;
    if fields.next().is_none() && uid == 0 && gid == 0 && mode & 0o077 == 0 {
        Ok(())
    } else {
        Err(format!(
            "{label} must be root:root without group/world access, observed {} at {}",
            observation.trim(),
            path.display()
        ))
    }
}

pub(super) fn assert_lifecycle_guards_released(
    unit: &str,
    drop_in_paths: &str,
) -> Result<(), String> {
    if !drop_in_paths.is_empty() {
        return Err(format!(
            "systemd lifecycle left effective drop-ins for {unit}: {drop_in_paths}"
        ));
    }
    let persistent = persistent_inhibitor_path(unit);
    if root_path_matches("-e", &persistent)? || root_path_matches("-L", &persistent)? {
        return Err(format!(
            "systemd lifecycle left its persistent inhibitor behind: {}",
            persistent.display()
        ));
    }
    assert_runtime_permit_artifacts_absent(unit)
}

pub(super) fn assert_transaction_guard_active(
    unit: &str,
    drop_in_paths: &str,
) -> Result<(), String> {
    let persistent = persistent_inhibitor_path(unit);
    if drop_in_paths != persistent.to_string_lossy() {
        return Err(format!(
            "systemd transaction guard for {unit} was {drop_in_paths:?}, expected {}",
            persistent.display()
        ));
    }
    if !root_path_matches("-f", &persistent)? {
        return Err(format!(
            "systemd transaction inhibitor is missing: {}",
            persistent.display()
        ));
    }
    assert_runtime_permit_artifacts_absent(unit)
}

pub(super) fn persistent_inhibitor_path(unit: &str) -> PathBuf {
    Path::new("/etc/systemd/system")
        .join(format!("{unit}.service.d"))
        .join("90-harness-inhibit.conf")
}

pub(super) fn runtime_permit_directory(unit: &str) -> PathBuf {
    Path::new("/run/systemd/system.control").join(format!("{unit}.service.d"))
}

pub(super) fn root_path_matches(predicate: &str, path: &Path) -> Result<bool, String> {
    let output = sudo([OsStr::new("test"), OsStr::new(predicate), path.as_os_str()])
        .output()
        .map_err(|error| format!("inspect root path {}: {error}", path.display()))?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) if output.stderr.is_empty() => Ok(false),
        _ => Err(format!(
            "inspect root path {} exited with {}; stderr={}",
            path.display(),
            output.status,
            String::from_utf8_lossy(&output.stderr)
        )),
    }
}

fn assert_systemd_state(verb: &str, unit: &str, expected: &[&str]) -> Result<(), String> {
    let output = Command::new("systemctl")
        .args([verb, unit])
        .output()
        .map_err(|error| format!("inspect {unit} with systemctl {verb}: {error}"))?;
    let observed = String::from_utf8_lossy(&output.stdout);
    let observed = observed.trim();
    if expected.contains(&observed) {
        return Ok(());
    }
    Err(format!(
        "systemctl {verb} {unit} reported {observed:?}, expected one of {expected:?}; exit={}; stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    ))
}

fn parse_decimal(value: Option<&str>, label: &str, field: &str) -> Result<u32, String> {
    let value = value.ok_or_else(|| format!("{label} stat omitted {field}"))?;
    value
        .parse::<u32>()
        .map_err(|error| format!("parse {label} {field} {value:?}: {error}"))
}

fn sudo<I, S>(args: I) -> Command
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("sudo");
    command.arg("-n").args(args);
    command
}
