use std::fs;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::workspace::utc_now;

use super::paths::manifest_lock_path;
use super::{
    DaemonManifest, daemon_lock_is_held, ensure_daemon_dirs, manifest_path,
    run_manifest_write_hook,
};

pub fn load_manifest() -> Result<Option<DaemonManifest>, CliError> {
    if !manifest_path().is_file() {
        return Ok(None);
    }
    read_json_typed(&manifest_path()).map(Some)
}

pub fn load_running_manifest() -> Result<Option<DaemonManifest>, CliError> {
    let Some(manifest) = load_manifest()? else {
        return Ok(None);
    };
    if daemon_lock_is_held() {
        return Ok(Some(manifest));
    }
    clear_manifest_for_pid(manifest.pid)?;
    Ok(None)
}

pub fn write_manifest(manifest: &DaemonManifest) -> Result<DaemonManifest, CliError> {
    ensure_daemon_dirs()?;
    with_exclusive_flock(
        &manifest_lock_path(),
        FlockErrorContext::new("daemon manifest"),
        || {
            let previous_revision = load_manifest().ok().flatten().map_or(0, |m| m.revision);
            run_manifest_write_hook();
            let next = DaemonManifest {
                revision: previous_revision.saturating_add(1),
                updated_at: utc_now(),
                ..manifest.clone()
            };
            write_json_pretty(&manifest_path(), &next)?;
            Ok(next)
        },
    )
}

pub fn clear_manifest_for_pid(pid: u32) -> Result<(), CliError> {
    let path = manifest_path();
    let Some(manifest) = load_manifest()? else {
        return Ok(());
    };
    if manifest.pid != pid || !path.exists() {
        return Ok(());
    }
    fs::remove_file(&path)
        .map_err(|error| CliErrorKind::workflow_io(format!("remove daemon manifest: {error}")))?;
    Ok(())
}
