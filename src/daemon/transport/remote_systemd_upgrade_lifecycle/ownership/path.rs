use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Component, Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;

use super::super::super::remote_systemd_lifecycle::validate_canonical_unit_name;
use super::super::files::io_error;

#[derive(Debug)]
pub(super) struct LifecyclePaths {
    pub(super) transaction_root: PathBuf,
    pub(super) store_path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct FileIdentity {
    pub(super) device: u64,
    pub(super) inode: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct BinaryOwnershipKey {
    pub(super) resolved_path: PathBuf,
    pub(super) parent: FileIdentity,
    pub(super) entry_name: String,
    pub(super) current_file: FileIdentity,
}

impl LifecyclePaths {
    pub(super) fn validate(
        transaction_root: &Path,
        unit: &str,
        store_path: &Path,
    ) -> Result<Self, CliError> {
        validate_canonical_unit_name(unit)?;
        let transaction_root =
            normalize_absolute_utf8("systemd transaction root", transaction_root)?;
        let store_path = normalize_absolute_utf8("systemd transaction store", store_path)?;
        let expected_store = transaction_root.join(unit);
        if store_path != expected_store {
            return Err(io_error(format!(
                "systemd transaction store must be exactly one unit below {}: expected {}, found {}",
                transaction_root.display(),
                expected_store.display(),
                store_path.display()
            )));
        }
        Ok(Self {
            transaction_root,
            store_path,
        })
    }
}

pub(super) fn normalize_absolute_utf8(label: &str, path: &Path) -> Result<PathBuf, CliError> {
    let rendered = path
        .to_str()
        .ok_or_else(|| io_error(format!("{label} must be a UTF-8 path: {}", path.display())))?;
    if !path.is_absolute() {
        return Err(io_error(format!(
            "{label} must be absolute: {}",
            path.display()
        )));
    }
    if rendered.chars().any(char::is_control) {
        return Err(io_error(format!(
            "{label} contains a control character: {}",
            path.display()
        )));
    }
    let mut normalized = PathBuf::from("/");
    let mut has_component = false;
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(value) => {
                has_component = true;
                normalized.push(value);
            }
            Component::CurDir | Component::ParentDir | Component::Prefix(_) => {
                return Err(io_error(format!(
                    "{label} contains a noncanonical component: {}",
                    path.display()
                )));
            }
        }
    }
    if !has_component || normalized.to_str() != Some(rendered) {
        return Err(io_error(format!(
            "{label} must be a normalized non-root path: {}",
            path.display()
        )));
    }
    Ok(normalized)
}

pub(super) fn resolve_binary_ownership_key(path: &Path) -> Result<BinaryOwnershipKey, CliError> {
    let current_file = current_binary_file_identity(path)?.ok_or_else(|| {
        io_error(format!(
            "systemd binary ownership path disappeared: {}",
            path.display()
        ))
    })?;
    let resolved = fs::canonicalize(path).map_err(|error| {
        io_error(format!(
            "resolve systemd binary ownership path {}: {error}",
            path.display()
        ))
    })?;
    let resolved_path =
        normalize_absolute_utf8("resolved systemd binary ownership path", &resolved)?;
    let parent_path = resolved_path.parent().ok_or_else(|| {
        io_error(format!(
            "resolved systemd binary ownership path has no parent: {}",
            resolved_path.display()
        ))
    })?;
    let parent_metadata = fs::metadata(parent_path).map_err(|error| {
        io_error(format!(
            "inspect resolved systemd binary parent {}: {error}",
            parent_path.display()
        ))
    })?;
    if !parent_metadata.is_dir() {
        return Err(io_error(format!(
            "resolved systemd binary parent is not a directory: {}",
            parent_path.display()
        )));
    }
    let entry_name = resolved_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            io_error(format!(
                "resolved systemd binary path has no UTF-8 filename: {}",
                resolved_path.display()
            ))
        })?
        .to_string();
    Ok(BinaryOwnershipKey {
        resolved_path,
        parent: FileIdentity {
            device: parent_metadata.dev(),
            inode: parent_metadata.ino(),
        },
        entry_name,
        current_file,
    })
}

pub(super) fn current_binary_file_identity(path: &Path) -> Result<Option<FileIdentity>, CliError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(io_error(format!(
                "inspect systemd binary ownership path {}: {error}",
                path.display()
            )));
        }
    };
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io_error(format!(
            "systemd binary ownership path is not a real regular file: {}",
            path.display()
        )));
    }
    Ok(Some(FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    }))
}
