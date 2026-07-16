use std::ffi::OsStr;
use std::fs::{OpenOptions, Permissions};
use std::io::ErrorKind;
use std::os::fd::RawFd;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process;

use fs_err as fs;
use nix::fcntl::{FcntlArg, fcntl};
use nix::unistd::{Gid, Uid, close, fchown};
use uuid::Uuid;

use crate::errors::CliError;

use self::storage::{
    OpenToken, create_token_directory, inspect_token_directory, open_exact_token,
    remove_empty_token_directory, remove_open_token, validate_token_metadata,
};
use super::storage::{open_directory, sync_directory};
use super::{MINIMUM_PERMIT_FD, io_error, trusted_owner};

const TOKEN_PREFIX: &str = ".harness-start-permit-";
const TOKEN_SUFFIX: &str = ".token";

#[path = "token/storage.rs"]
mod storage;

pub(super) struct LivenessToken {
    raw: Option<RawFd>,
    parent: PathBuf,
    directory: PathBuf,
    path: PathBuf,
    condition_path: PathBuf,
    present: bool,
}

pub(super) struct StaleLivenessToken {
    token: Option<OpenToken>,
    parent: PathBuf,
    directory: Option<PathBuf>,
}

impl LivenessToken {
    pub(super) fn create(parent: &Path) -> Result<Self, CliError> {
        let identity = Uuid::new_v4().simple().to_string();
        let token_name = format!("{TOKEN_PREFIX}{identity}{TOKEN_SUFFIX}");
        let directory = parent.join(format!("{TOKEN_PREFIX}{identity}"));
        create_token_directory(&directory, parent)?;
        let source = match open_directory(&directory) {
            Ok(source) => source,
            Err(error) => {
                remove_empty_token_directory(&directory, parent);
                return Err(error);
            }
        };
        let raw = match fcntl(&source, FcntlArg::F_DUPFD_CLOEXEC(MINIMUM_PERMIT_FD)) {
            Ok(raw) => raw,
            Err(error) => {
                remove_empty_token_directory(&directory, parent);
                return Err(io_error(format!(
                    "duplicate runtime permit liveness descriptor: {error}"
                )));
            }
        };
        if raw < MINIMUM_PERMIT_FD {
            let _ = close(raw);
            remove_empty_token_directory(&directory, parent);
            return Err(io_error(format!(
                "runtime permit descriptor {raw} is below {MINIMUM_PERMIT_FD}"
            )));
        }
        let path = directory.join(&token_name);
        let condition_path = render_condition_path(raw, &token_name, &path);
        let mut token = Self {
            raw: Some(raw),
            parent: parent.to_path_buf(),
            directory,
            path,
            condition_path,
            present: true,
        };
        token.install()?;
        Ok(token)
    }

    pub(super) fn condition_path(&self) -> &Path {
        &self.condition_path
    }

    pub(super) fn require_live(&self) -> Result<(), CliError> {
        if !self.present {
            return Err(io_error("runtime permit liveness token is not installed"));
        }
        let token = StaleLivenessToken::inspect(&self.parent, &self.condition_path)?;
        if token.condition_is_live(&self.condition_path)? {
            Ok(())
        } else {
            Err(io_error(format!(
                "runtime permit liveness condition does not resolve to its identity token: {}",
                self.condition_path.display()
            )))
        }
    }

    pub(super) fn remove(&mut self) -> Result<(), CliError> {
        if self.present {
            StaleLivenessToken::inspect(&self.parent, &self.condition_path)?.remove()?;
            self.present = false;
        }
        Ok(())
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(super) fn close_descriptor_for_tests(&mut self) -> Result<(), CliError> {
        if let Some(raw) = self.raw.take() {
            close(raw).map_err(|error| {
                io_error(format!("close runtime permit descriptor for test: {error}"))
            })?;
        }
        Ok(())
    }

    fn install(&mut self) -> Result<(), CliError> {
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&self.path)
            .map_err(|error| {
                io_error(format!(
                    "create runtime permit liveness token {}: {error}",
                    self.path.display()
                ))
            })?;
        file.set_permissions(Permissions::from_mode(0o600))
            .map_err(|error| {
                io_error(format!(
                    "set runtime permit liveness token permissions {}: {error}",
                    self.path.display()
                ))
            })?;
        let (uid, gid) = trusted_owner();
        fchown(&file, Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid))).map_err(|error| {
            io_error(format!(
                "set runtime permit liveness token ownership {}: {error}",
                self.path.display()
            ))
        })?;
        file.sync_all().map_err(|error| {
            io_error(format!(
                "sync runtime permit liveness token {}: {error}",
                self.path.display()
            ))
        })?;
        validate_token_metadata(
            &self.path,
            &file.metadata().map_err(|error| {
                io_error(format!(
                    "inspect runtime permit liveness token {}: {error}",
                    self.path.display()
                ))
            })?,
        )?;
        sync_directory(&self.directory)
    }
}

impl Drop for LivenessToken {
    fn drop(&mut self) {
        let _ = self.remove();
        if let Some(raw) = self.raw.take() {
            let _ = close(raw);
        }
    }
}

impl StaleLivenessToken {
    pub(super) fn inspect(parent: &Path, condition_path: &Path) -> Result<Self, CliError> {
        let token_name = condition_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| io_error("runtime permit condition has no UTF-8 identity token"))?;
        let identity = token_identity(token_name)?;
        let directory = parent.join(format!("{TOKEN_PREFIX}{identity}"));
        if !inspect_token_directory(&directory)? {
            return Ok(Self {
                token: None,
                parent: parent.to_path_buf(),
                directory: None,
            });
        }
        let path = directory.join(token_name);
        let entries = fs::read_dir(&directory)
            .map_err(|error| {
                io_error(format!(
                    "inspect runtime permit token directory {}: {error}",
                    directory.display()
                ))
            })?
            .map(|entry| {
                entry.map(|value| value.file_name()).map_err(|error| {
                    io_error(format!(
                        "inspect runtime permit token directory entry {}: {error}",
                        directory.display()
                    ))
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        if entries.len() > 1
            || entries
                .first()
                .is_some_and(|entry| entry != OsStr::new(token_name))
        {
            return Err(io_error(format!(
                "runtime permit token directory contains unrelated entries: {}",
                directory.display()
            )));
        }
        Ok(Self {
            token: open_exact_token(&path)?,
            parent: parent.to_path_buf(),
            directory: Some(directory),
        })
    }

    pub(super) fn remove(self) -> Result<(), CliError> {
        if let Some(token) = self.token {
            let directory = self
                .directory
                .as_deref()
                .ok_or_else(|| io_error("runtime permit token has no owned directory"))?;
            remove_open_token(&token, directory)?;
            drop(token);
        }
        if let Some(directory) = self.directory {
            fs::remove_dir(&directory).map_err(|error| {
                io_error(format!(
                    "remove runtime permit token directory {}: {error}",
                    directory.display()
                ))
            })?;
            sync_directory(&self.parent)?;
        }
        Ok(())
    }

    pub(super) fn condition_is_live(&self, condition_path: &Path) -> Result<bool, CliError> {
        let Some(token) = self.token.as_ref() else {
            return Ok(false);
        };
        let condition = match fs::metadata(condition_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
            Err(error) => {
                return Err(io_error(format!(
                    "inspect runtime permit liveness condition {}: {error}",
                    condition_path.display()
                )));
            }
        };
        let identity = token.file.metadata().map_err(|error| {
            io_error(format!(
                "inspect runtime permit liveness identity {}: {error}",
                token.path.display()
            ))
        })?;
        Ok(condition.dev() == identity.dev() && condition.ino() == identity.ino())
    }
}

pub(super) fn remove_orphaned_liveness_tokens(parent: &Path) -> Result<bool, CliError> {
    let mut tokens = Vec::new();
    for entry in fs::read_dir(parent).map_err(|error| {
        io_error(format!(
            "inspect runtime permit directory for orphaned tokens {}: {error}",
            parent.display()
        ))
    })? {
        let entry = entry.map_err(|error| {
            io_error(format!(
                "inspect runtime permit directory entry {}: {error}",
                parent.display()
            ))
        })?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(identity) = name.strip_prefix(TOKEN_PREFIX) else {
            continue;
        };
        if !canonical_uuid(identity) {
            continue;
        }
        let token_name = format!("{TOKEN_PREFIX}{identity}{TOKEN_SUFFIX}");
        tokens.push(StaleLivenessToken::inspect(parent, Path::new(&token_name))?);
    }
    let removed = !tokens.is_empty();
    for token in tokens {
        token.remove()?;
    }
    Ok(removed)
}

pub(super) fn validate_condition_token_name(name: &str) -> Result<(), CliError> {
    token_identity(name).map(|_| ())
}

fn token_identity(name: &str) -> Result<&str, CliError> {
    let identity = name
        .strip_prefix(TOKEN_PREFIX)
        .and_then(|value| value.strip_suffix(TOKEN_SUFFIX))
        .ok_or_else(|| io_error("runtime systemd start permit has an invalid identity token"))?;
    if canonical_uuid(identity) {
        Ok(identity)
    } else {
        Err(io_error(
            "runtime systemd start permit identity token is not canonical",
        ))
    }
}

fn canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|uuid| uuid.simple().to_string() == value)
}

#[cfg(target_os = "linux")]
fn render_condition_path(raw: RawFd, token_name: &str, _token_path: &Path) -> PathBuf {
    PathBuf::from(format!("/proc/{}/fd/{raw}/{token_name}", process::id()))
}

#[cfg(not(target_os = "linux"))]
fn render_condition_path(_raw: RawFd, _token_name: &str, token_path: &Path) -> PathBuf {
    token_path.to_path_buf()
}
