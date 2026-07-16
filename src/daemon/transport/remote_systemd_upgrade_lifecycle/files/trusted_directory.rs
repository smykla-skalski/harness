#[cfg(test)]
use std::env::temp_dir;
use std::fs::{DirBuilder, Metadata};
use std::io::ErrorKind;
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _};
use std::path::{Component, Path, PathBuf};

use fs_err as fs;

use crate::errors::CliError;

use super::super::model::FileMetadata;
use super::{apply_path_metadata, io_error, sync_directory, sync_parent, validate_absolute_path};

pub(in super::super) fn create_private_directory(path: &Path) -> Result<(), CliError> {
    validate_absolute_path("private directory", path)?;
    let boundary = trusted_boundary(path)?;
    validate_trusted_directory(&boundary, "private directory trust boundary")?;
    let mut current = boundary.clone();
    for component in path
        .strip_prefix(&boundary)
        .map_err(|_| io_error("private directory is outside its trust boundary"))?
        .components()
    {
        let Component::Normal(component) = component else {
            return Err(io_error(format!(
                "private directory contains an invalid component: {}",
                path.display()
            )));
        };
        current.push(component);
        ensure_trusted_directory(&current)?;
    }
    apply_path_metadata(&current, FileMetadata::private_executable())?;
    validate_private_directory(path)?;
    sync_directory(path)?;
    sync_parent(path)
}

pub(in super::super) fn validate_private_directory(path: &Path) -> Result<(), CliError> {
    validate_absolute_path("private directory", path)?;
    let boundary = trusted_boundary(path)?;
    let mut current = boundary.clone();
    validate_trusted_directory(&current, "private directory trust boundary")?;
    for component in path
        .strip_prefix(&boundary)
        .map_err(|_| io_error("private directory is outside its trust boundary"))?
        .components()
    {
        let Component::Normal(component) = component else {
            return Err(io_error(format!(
                "private directory contains an invalid component: {}",
                path.display()
            )));
        };
        current.push(component);
        validate_trusted_directory(&current, "private directory ancestor")?;
    }
    let metadata = trusted_directory_metadata(path, "private directory")?;
    if metadata.mode().trailing_zeros() >= 6 {
        Ok(())
    } else {
        Err(io_error(format!(
            "private directory must not grant group or world access: {}",
            path.display()
        )))
    }
}

fn ensure_trusted_directory(path: &Path) -> Result<(), CliError> {
    match fs::symlink_metadata(path) {
        Ok(_) => validate_trusted_directory(path, "existing private directory ancestor"),
        Err(error) if error.kind() == ErrorKind::NotFound => create_trusted_directory(path),
        Err(error) => Err(io_error(format!(
            "inspect private directory ancestor {}: {error}",
            path.display()
        ))),
    }
}

fn create_trusted_directory(path: &Path) -> Result<(), CliError> {
    let mut builder = DirBuilder::new();
    builder.mode(0o700);
    match builder.create(path) {
        Ok(()) => {
            apply_path_metadata(path, FileMetadata::private_executable())?;
            validate_trusted_directory(path, "created private directory ancestor")?;
            sync_parent(path)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            validate_trusted_directory(path, "raced private directory ancestor")
        }
        Err(error) => Err(io_error(format!(
            "create private directory {}: {error}",
            path.display()
        ))),
    }
}

fn validate_trusted_directory(path: &Path, label: &str) -> Result<(), CliError> {
    trusted_directory_metadata(path, label).map(|_| ())
}

fn trusted_directory_metadata(path: &Path, label: &str) -> Result<Metadata, CliError> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| io_error(format!("inspect {label} {}: {error}", path.display())))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io_error(format!(
            "{label} is not a real directory: {}",
            path.display()
        )));
    }
    if metadata.uid() != trusted_uid() {
        return Err(io_error(format!(
            "{label} must be owned by uid {}: {} is owned by uid {}",
            trusted_uid(),
            path.display(),
            metadata.uid()
        )));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(io_error(format!(
            "{label} must not be group or world writable: {}",
            path.display()
        )));
    }
    Ok(metadata)
}

#[cfg(not(test))]
fn trusted_boundary(path: &Path) -> Result<PathBuf, CliError> {
    path.ancestors()
        .find(|ancestor| *ancestor == Path::new("/"))
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            io_error(format!(
                "private directory has no trusted filesystem root: {}",
                path.display()
            ))
        })
}

#[cfg(test)]
fn trusted_boundary(path: &Path) -> Result<PathBuf, CliError> {
    let temporary_root = temp_dir();
    let relative = path.strip_prefix(&temporary_root).map_err(|_| {
        io_error(format!(
            "test private directory must be below the temporary directory {}: {}",
            temporary_root.display(),
            path.display()
        ))
    })?;
    let Some(Component::Normal(first)) = relative.components().next() else {
        return Err(io_error(format!(
            "test private directory requires a secure boundary below {}: {}",
            temporary_root.display(),
            path.display()
        )));
    };
    Ok(temporary_root.join(first))
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}

#[cfg(test)]
mod tests {
    use std::fs::Permissions;
    use std::os::unix::fs::{PermissionsExt as _, symlink};

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn private_directory_creation_rejects_symlink_ancestry() {
        let temp = tempdir().expect("temporary directory");
        let destination = temp.path().join("destination");
        fs::create_dir(&destination).expect("destination");
        let link = temp.path().join("link");
        symlink(&destination, &link).expect("symlink ancestor");

        let error = create_private_directory(&link.join("store"))
            .expect_err("symlink ancestry must fail closed");

        assert!(error.to_string().contains("not a real directory"));
        assert!(!destination.join("store").exists());
    }

    #[test]
    fn private_directory_creation_rejects_writable_ancestry() {
        let temp = tempdir().expect("temporary directory");
        let writable = temp.path().join("writable");
        fs::create_dir(&writable).expect("writable ancestor");
        fs::set_permissions(&writable, Permissions::from_mode(0o770))
            .expect("writable permissions");

        let error = create_private_directory(&writable.join("store"))
            .expect_err("writable ancestry must fail closed");

        assert!(error.to_string().contains("group or world writable"));
        assert!(!writable.join("store").exists());
    }

    #[test]
    fn private_directory_creation_builds_private_real_components() {
        let temp = tempdir().expect("temporary directory");
        let store = temp.path().join("transactions").join("unit");

        create_private_directory(&store).expect("trusted private directory");

        for path in [temp.path().join("transactions"), store] {
            let metadata = fs::symlink_metadata(path).expect("created directory metadata");
            assert!(metadata.is_dir());
            assert!(!metadata.file_type().is_symlink());
            assert_eq!(metadata.uid(), uzers::get_current_uid());
            assert_eq!(metadata.mode() & 0o077, 0);
        }
    }
}
