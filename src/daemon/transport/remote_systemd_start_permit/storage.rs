use std::fs::{DirBuilder, File, Metadata, OpenOptions, Permissions};
use std::io::{ErrorKind, Read as _, Write as _};
use std::os::unix::fs::{
    DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _,
};
use std::path::{Path, PathBuf};

use fs_err as fs;
use nix::unistd::{Gid, Uid, fchown};
use tempfile::NamedTempFile;

use crate::errors::CliError;

use super::{io_error, parse_condition_path, trusted_gid, trusted_owner, trusted_uid};

pub(super) struct PermitFile {
    pub(super) file: File,
    pub(super) bytes: Vec<u8>,
    pub(super) condition_path: PathBuf,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(super) enum DirectoryState {
    Absent,
    Present,
}

pub(super) fn install_exact_permit(
    path: &Path,
    parent: &Path,
    bytes: &[u8],
) -> Result<(), CliError> {
    let mut temporary = NamedTempFile::new_in(parent).map_err(|error| {
        io_error(format!(
            "create temporary runtime systemd permit for {}: {error}",
            path.display()
        ))
    })?;
    temporary.write_all(bytes).map_err(|error| {
        io_error(format!(
            "write temporary runtime systemd permit for {}: {error}",
            path.display()
        ))
    })?;
    temporary
        .as_file()
        .set_permissions(Permissions::from_mode(0o644))
        .map_err(|error| {
            io_error(format!(
                "set runtime systemd permit permissions {}: {error}",
                path.display()
            ))
        })?;
    let (uid, gid) = trusted_owner();
    fchown(
        temporary.as_file(),
        Some(Uid::from_raw(uid)),
        Some(Gid::from_raw(gid)),
    )
    .map_err(|error| {
        io_error(format!(
            "set runtime systemd permit ownership {}: {error}",
            path.display()
        ))
    })?;
    temporary.as_file().sync_all().map_err(|error| {
        io_error(format!(
            "sync runtime systemd permit {}: {error}",
            path.display()
        ))
    })?;
    temporary.persist_noclobber(path).map_err(|error| {
        io_error(format!(
            "persist runtime systemd permit {}: {}",
            path.display(),
            error.error
        ))
    })?;
    sync_directory(parent)
}

pub(super) fn ensure_exact_directory(path: &Path, parent: &Path) -> Result<(), CliError> {
    if inspect_exact_directory(path)? == DirectoryState::Present {
        return sync_directory(path);
    }
    let mut builder = DirBuilder::new();
    builder.mode(0o755);
    match builder.create(path) {
        Ok(()) => {
            secure_directory(path)?;
            sync_directory(parent)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if inspect_exact_directory(path)? != DirectoryState::Present {
                return Err(io_error(format!(
                    "runtime systemd control directory disappeared: {}",
                    path.display()
                )));
            }
            sync_directory(path)
        }
        Err(error) => Err(io_error(format!(
            "create runtime systemd control directory {}: {error}",
            path.display()
        ))),
    }
}

pub(super) fn inspect_exact_directory(path: &Path) -> Result<DirectoryState, CliError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(DirectoryState::Absent),
        Err(error) => {
            return Err(io_error(format!(
                "inspect runtime systemd control directory {}: {error}",
                path.display()
            )));
        }
    };
    validate_directory(path, &metadata)?;
    Ok(DirectoryState::Present)
}

fn secure_directory(path: &Path) -> Result<(), CliError> {
    let directory = open_directory(path)?;
    let (uid, gid) = trusted_owner();
    fchown(
        &directory,
        Some(Uid::from_raw(uid)),
        Some(Gid::from_raw(gid)),
    )
    .map_err(|error| {
        io_error(format!(
            "set runtime systemd control ownership {}: {error}",
            path.display()
        ))
    })?;
    directory
        .set_permissions(Permissions::from_mode(0o755))
        .map_err(|error| {
            io_error(format!(
                "set runtime systemd control permissions {}: {error}",
                path.display()
            ))
        })?;
    directory.sync_all().map_err(|error| {
        io_error(format!(
            "sync runtime systemd control directory {}: {error}",
            path.display()
        ))
    })?;
    validate_directory(
        path,
        &directory.metadata().map_err(|error| {
            io_error(format!(
                "inspect runtime systemd control directory {}: {error}",
                path.display()
            ))
        })?,
    )
}

fn validate_directory(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io_error(format!(
            "runtime systemd control path is not a real directory: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.gid() != trusted_gid() {
        return Err(io_error(format!(
            "runtime systemd control directory has untrusted owner {}:{}: {}",
            metadata.uid(),
            metadata.gid(),
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != 0o755 {
        return Err(io_error(format!(
            "runtime systemd control directory must have mode 0755, found {:04o}: {}",
            metadata.mode() & 0o7777,
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn open_permit(path: &Path) -> Result<Option<PermitFile>, CliError> {
    let initial = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(io_error(format!(
                "inspect runtime systemd start permit {}: {error}",
                path.display()
            )));
        }
    };
    validate_permit_metadata(path, &initial)?;
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| {
            io_error(format!(
                "open runtime systemd start permit {}: {error}",
                path.display()
            ))
        })?;
    let opened = file.metadata().map_err(|error| {
        io_error(format!(
            "inspect open runtime systemd start permit {}: {error}",
            path.display()
        ))
    })?;
    validate_permit_metadata(path, &opened)?;
    if initial.dev() != opened.dev() || initial.ino() != opened.ino() {
        return Err(io_error(format!(
            "runtime systemd start permit changed while opening: {}",
            path.display()
        )));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|error| {
        io_error(format!(
            "read runtime systemd start permit {}: {error}",
            path.display()
        ))
    })?;
    let condition_path = parse_condition_path(&bytes)?;
    Ok(Some(PermitFile {
        file,
        bytes,
        condition_path,
    }))
}

fn validate_permit_metadata(path: &Path, metadata: &Metadata) -> Result<(), CliError> {
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io_error(format!(
            "runtime systemd start permit is not a regular file: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() || metadata.gid() != trusted_gid() {
        return Err(io_error(format!(
            "runtime systemd start permit has untrusted owner {}:{}: {}",
            metadata.uid(),
            metadata.gid(),
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != 0o644 || metadata.nlink() != 1 {
        return Err(io_error(format!(
            "runtime systemd start permit must have mode 0644 and one link: {}",
            path.display()
        )));
    }
    Ok(())
}

pub(super) fn remove_open_permit(
    path: &Path,
    parent: &Path,
    permit: &PermitFile,
) -> Result<(), CliError> {
    let current = fs::symlink_metadata(path).map_err(|error| {
        io_error(format!(
            "inspect runtime systemd start permit before removal {}: {error}",
            path.display()
        ))
    })?;
    validate_permit_metadata(path, &current)?;
    let opened = permit.file.metadata().map_err(|error| {
        io_error(format!(
            "inspect open runtime systemd start permit before removal {}: {error}",
            path.display()
        ))
    })?;
    if current.dev() != opened.dev() || current.ino() != opened.ino() {
        return Err(io_error(format!(
            "runtime systemd start permit changed before removal: {}",
            path.display()
        )));
    }
    fs::remove_file(path).map_err(|error| {
        io_error(format!(
            "remove runtime systemd start permit {}: {error}",
            path.display()
        ))
    })?;
    sync_directory(parent)
}

pub(super) fn remove_empty_directory(path: &Path, parent: &Path) -> Result<(), CliError> {
    match fs::remove_dir(path) {
        Ok(()) => sync_directory(parent),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) if error.kind() == ErrorKind::DirectoryNotEmpty => Ok(()),
        Err(error) => Err(io_error(format!(
            "remove empty runtime systemd control directory {}: {error}",
            path.display()
        ))),
    }
}

pub(super) fn validate_trusted_ancestors(path: &Path) -> Result<(), CliError> {
    for ancestor in path.ancestors() {
        let metadata = fs::symlink_metadata(ancestor).map_err(|error| {
            io_error(format!(
                "inspect runtime systemd directory ancestor {}: {error}",
                ancestor.display()
            ))
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io_error(format!(
                "runtime systemd directory ancestor is not a real directory: {}",
                ancestor.display()
            )));
        }
        if metadata.uid() != 0 && metadata.uid() != trusted_uid() {
            return Err(io_error(format!(
                "runtime systemd directory ancestor has untrusted owner {}: {}",
                metadata.uid(),
                ancestor.display()
            )));
        }
        let sticky_root = metadata.uid() == 0 && metadata.mode() & 0o1000 != 0;
        if metadata.mode() & 0o022 != 0 && !sticky_root {
            return Err(io_error(format!(
                "runtime systemd directory ancestor is group- or world-writable: {}",
                ancestor.display()
            )));
        }
    }
    Ok(())
}

pub(super) fn open_directory(path: &Path) -> Result<File, CliError> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| {
            io_error(format!(
                "open runtime systemd control directory {}: {error}",
                path.display()
            ))
        })
}

pub(super) fn sync_directory(path: &Path) -> Result<(), CliError> {
    open_directory(path)?.sync_all().map_err(|error| {
        io_error(format!(
            "sync runtime systemd control directory {}: {error}",
            path.display()
        ))
    })
}
