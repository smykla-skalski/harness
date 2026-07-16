use std::io::ErrorKind;
use std::os::fd::RawFd;
use std::path::{Component, Path, PathBuf};
use std::str;

use fs_err as fs;
#[cfg(test)]
use nix::unistd::{Gid, Uid};

use crate::errors::{CliError, CliErrorKind};

use storage::{
    DirectoryState, ensure_exact_directory, inspect_exact_directory, install_exact_permit,
    open_permit, remove_empty_directory, remove_open_permit, validate_trusted_ancestors,
};
use token::{
    LivenessToken, StaleLivenessToken, remove_orphaned_liveness_tokens,
    validate_condition_token_name,
};

#[path = "remote_systemd_start_permit/storage.rs"]
mod storage;
#[path = "remote_systemd_start_permit/token.rs"]
mod token;

const PERMIT_FILE_NAME: &str = "90-harness-inhibit.conf";
const PERMIT_PREFIX: &str = "[Unit]\nConditionPathExists=";
const MINIMUM_PERMIT_FD: RawFd = 512;
#[cfg(not(test))]
const RUNTIME_CONTROL_ROOT: &str = "/run/systemd/system.control";

pub(crate) struct RuntimeStartPermit {
    path: PathBuf,
    bytes: Vec<u8>,
    liveness: LivenessToken,
}

impl RuntimeStartPermit {
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn require_live(&self, unit_path: &Path) -> Result<(), CliError> {
        let expected_path = runtime_start_permit_path(unit_path)?;
        if self.path != expected_path {
            return Err(io_error(format!(
                "runtime systemd start permit has unexpected path: {}",
                self.path.display()
            )));
        }
        if !runtime_start_permit_is_live(unit_path)? {
            return Err(io_error(format!(
                "runtime systemd start permit is not live: {}",
                self.path.display()
            )));
        }
        let permit = open_permit(&self.path)?.ok_or_else(|| {
            io_error(format!(
                "runtime systemd start permit disappeared: {}",
                self.path.display()
            ))
        })?;
        if permit.bytes != self.bytes || permit.condition_path != self.liveness.condition_path() {
            return Err(io_error(format!(
                "runtime systemd start permit changed after installation: {}",
                self.path.display()
            )));
        }
        self.liveness.require_live()
    }

    #[cfg(test)]
    pub(crate) fn expire_liveness_for_tests(&mut self) -> Result<(), CliError> {
        self.liveness.remove()
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn close_liveness_descriptor_for_tests(&mut self) -> Result<(), CliError> {
        self.liveness.close_descriptor_for_tests()
    }

    pub(crate) fn remove(mut self) -> Result<(), CliError> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| io_error("runtime systemd permit has no parent"))?;
        let control_root = parent
            .parent()
            .ok_or_else(|| io_error("runtime systemd permit directory has no parent"))?;
        remove_owned_permit(&self.path, &self.bytes)?;
        self.liveness.remove()?;
        remove_empty_directory(parent, control_root)
    }
}

pub(crate) fn runtime_start_permit_path(unit_path: &Path) -> Result<PathBuf, CliError> {
    validate_absolute_normalized(unit_path)?;
    let service = service_file_name(unit_path)?;
    Ok(runtime_control_root(unit_path)
        .join(format!("{service}.d"))
        .join(PERMIT_FILE_NAME))
}

pub(crate) fn install_runtime_start_permit(
    unit_path: &Path,
) -> Result<RuntimeStartPermit, CliError> {
    let path = runtime_start_permit_path(unit_path)?;
    require_runtime_start_permit_absent(unit_path)?;
    let control_root = runtime_control_root(unit_path);
    let control_parent = control_root
        .parent()
        .ok_or_else(|| io_error("runtime systemd control root has no parent"))?;
    validate_trusted_ancestors(control_parent)?;
    ensure_exact_directory(&control_root, control_parent)?;
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error("runtime systemd permit has no parent"))?;
    ensure_exact_directory(drop_in_directory, &control_root)?;

    let liveness = LivenessToken::create(drop_in_directory)?;
    let condition_path = liveness.condition_path().to_path_buf();
    liveness.require_live()?;
    let bytes = format!("{PERMIT_PREFIX}{}\n", condition_path.display()).into_bytes();
    install_exact_permit(&path, drop_in_directory, &bytes)?;
    Ok(RuntimeStartPermit {
        path,
        bytes,
        liveness,
    })
}

pub(crate) fn remove_stale_runtime_start_permit(unit_path: &Path) -> Result<bool, CliError> {
    let path = runtime_start_permit_path(unit_path)?;
    let control_root = runtime_control_root(unit_path);
    if inspect_exact_directory(&control_root)? == DirectoryState::Absent {
        return Ok(false);
    }
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error("runtime systemd permit has no parent"))?;
    if inspect_exact_directory(drop_in_directory)? == DirectoryState::Absent {
        return Ok(false);
    }
    let Some(permit) = open_permit(&path)? else {
        let removed = remove_orphaned_liveness_tokens(drop_in_directory)?;
        remove_empty_directory(drop_in_directory, &control_root)?;
        return Ok(removed);
    };
    let stale_liveness = StaleLivenessToken::inspect(drop_in_directory, &permit.condition_path)?;
    if stale_liveness.condition_is_live(&permit.condition_path)? {
        return Err(io_error(format!(
            "refusing to remove a live runtime systemd start permit: {}",
            path.display()
        )));
    }
    remove_open_permit(&path, drop_in_directory, &permit)?;
    drop(permit);
    stale_liveness.remove()?;
    remove_empty_directory(drop_in_directory, &control_root)?;
    Ok(true)
}

pub(crate) fn require_runtime_start_permit_absent(unit_path: &Path) -> Result<(), CliError> {
    let path = runtime_start_permit_path(unit_path)?;
    let control_root = runtime_control_root(unit_path);
    if inspect_exact_directory(&control_root)? == DirectoryState::Absent {
        return Ok(());
    }
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error("runtime systemd permit has no parent"))?;
    if inspect_exact_directory(drop_in_directory)? == DirectoryState::Absent {
        return Ok(());
    }
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Ok(_) => Err(io_error(format!(
            "runtime systemd start permit remains installed: {}",
            path.display()
        ))),
        Err(error) => Err(io_error(format!(
            "inspect runtime systemd start permit {}: {error}",
            path.display()
        ))),
    }
}

pub(crate) fn runtime_start_permit_is_live(unit_path: &Path) -> Result<bool, CliError> {
    let path = runtime_start_permit_path(unit_path)?;
    let control_root = runtime_control_root(unit_path);
    if inspect_exact_directory(&control_root)? == DirectoryState::Absent {
        return Ok(false);
    }
    let drop_in_directory = path
        .parent()
        .ok_or_else(|| io_error("runtime systemd permit has no parent"))?;
    if inspect_exact_directory(drop_in_directory)? == DirectoryState::Absent {
        return Ok(false);
    }
    let Some(permit) = open_permit(&path)? else {
        return Ok(false);
    };
    StaleLivenessToken::inspect(drop_in_directory, &permit.condition_path)?
        .condition_is_live(&permit.condition_path)
}

fn remove_owned_permit(path: &Path, expected: &[u8]) -> Result<(), CliError> {
    let permit = open_permit(path)?.ok_or_else(|| {
        io_error(format!(
            "runtime systemd start permit disappeared before removal: {}",
            path.display()
        ))
    })?;
    if permit.bytes != expected {
        return Err(io_error(format!(
            "runtime systemd start permit changed before removal: {}",
            path.display()
        )));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io_error("runtime systemd permit has no parent"))?;
    remove_open_permit(path, parent, &permit)?;
    drop(permit);
    Ok(())
}

fn parse_condition_path(bytes: &[u8]) -> Result<PathBuf, CliError> {
    let contents = str::from_utf8(bytes)
        .map_err(|error| io_error(format!("decode runtime systemd start permit: {error}")))?;
    let condition = contents
        .strip_prefix(PERMIT_PREFIX)
        .and_then(|value| value.strip_suffix('\n'))
        .ok_or_else(|| io_error("refusing unrelated runtime systemd start permit"))?;
    validate_condition_path(condition)?;
    Ok(PathBuf::from(condition))
}

#[cfg(target_os = "linux")]
fn validate_condition_path(condition: &str) -> Result<(), CliError> {
    let descriptor = condition
        .strip_prefix("/proc/")
        .and_then(|value| value.split_once("/fd/"))
        .ok_or_else(|| io_error("runtime systemd start permit has an invalid condition path"))?;
    let pid = descriptor
        .0
        .parse::<u32>()
        .map_err(|error| io_error(format!("parse runtime permit process id: {error}")))?;
    let (fd, token_name) = descriptor
        .1
        .split_once('/')
        .ok_or_else(|| io_error("runtime systemd start permit has no identity token"))?;
    let fd = fd
        .parse::<RawFd>()
        .map_err(|error| io_error(format!("parse runtime permit descriptor: {error}")))?;
    if pid == 0 || fd < MINIMUM_PERMIT_FD {
        return Err(io_error(
            "runtime systemd start permit condition is out of range",
        ));
    }
    validate_condition_token_name(token_name)?;
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn validate_condition_path(condition: &str) -> Result<(), CliError> {
    let path = Path::new(condition);
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(io_error(
            "runtime systemd start permit has an invalid non-Linux condition path",
        ));
    }
    let token_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io_error("runtime systemd start permit has no identity token"))?;
    validate_condition_token_name(token_name)
}

fn validate_absolute_normalized(path: &Path) -> Result<(), CliError> {
    if path.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "systemd unit path must be absolute and normalized: {}",
            path.display()
        )))
    }
}

fn service_file_name(unit_path: &Path) -> Result<&str, CliError> {
    let service = unit_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io_error("systemd unit path requires a UTF-8 service filename"))?;
    if service
        .strip_suffix(".service")
        .is_some_and(|stem| !stem.is_empty())
    {
        Ok(service)
    } else {
        Err(io_error(format!(
            "systemd unit path must end in .service: {}",
            unit_path.display()
        )))
    }
}

#[cfg(not(test))]
fn runtime_control_root(_unit_path: &Path) -> PathBuf {
    PathBuf::from(RUNTIME_CONTROL_ROOT)
}

#[cfg(test)]
fn runtime_control_root(unit_path: &Path) -> PathBuf {
    unit_path.with_file_name("run-systemd-system.control")
}

fn trusted_owner() -> (u32, u32) {
    (trusted_uid(), trusted_gid())
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    Uid::effective().as_raw()
}

#[cfg(not(test))]
const fn trusted_gid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_gid() -> u32 {
    Gid::effective().as_raw()
}

fn io_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(detail.into()).into()
}

#[cfg(test)]
#[path = "remote_systemd_start_permit/tests.rs"]
mod tests;
