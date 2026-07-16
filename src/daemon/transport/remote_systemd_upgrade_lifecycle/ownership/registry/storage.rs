use std::fs::{File, Metadata, OpenOptions, Permissions};
use std::io::{ErrorKind, Read as _, Write as _};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::Path;

use fs_err as fs;
use tempfile::Builder;

use crate::errors::CliError;

use super::super::super::files::{sync_directory, validate_private_directory};
use super::{RegistryDocument, registry_error};

const REGISTRY_FILE: &str = ".binary-claims.json";
const REGISTRY_TEMP_PREFIX: &str = ".binary-claims.json.tmp-";
const REGISTRY_MODE: u32 = 0o600;
const MAX_REGISTRY_BYTES: u64 = 1024 * 1024;

pub(super) fn load_document(transaction_root: &Path) -> Result<Option<RegistryDocument>, CliError> {
    validate_private_directory(transaction_root)?;
    reconcile_registry_temporaries(transaction_root)?;
    let path = transaction_root.join(REGISTRY_FILE);
    let Some(file) = open_registry(&path)? else {
        return Ok(None);
    };
    let metadata = validate_open_registry(&file, &path)?;
    validate_registry_size(metadata.len(), &path)?;
    let mut bytes = Vec::new();
    file.take(MAX_REGISTRY_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| {
            registry_error(format!(
                "read binary claim registry {}: {error}",
                path.display()
            ))
        })?;
    let observed_len = u64::try_from(bytes.len())
        .map_err(|error| registry_error(format!("measure binary claim registry: {error}")))?;
    validate_registry_size(observed_len, &path)?;
    serde_json::from_slice(&bytes).map(Some).map_err(|error| {
        registry_error(format!(
            "decode binary claim registry {}: {error}",
            path.display()
        ))
    })
}

pub(super) fn persist_document(
    transaction_root: &Path,
    document: &RegistryDocument,
) -> Result<(), CliError> {
    validate_private_directory(transaction_root)?;
    reconcile_registry_temporaries(transaction_root)?;
    let path = transaction_root.join(REGISTRY_FILE);
    validate_registry_destination(&path)?;
    let bytes = encode_document(document)?;
    let mut temporary = Builder::new()
        .prefix(REGISTRY_TEMP_PREFIX)
        .tempfile_in(transaction_root)
        .map_err(|error| {
            registry_error(format!(
                "create binary claim registry temporary in {}: {error}",
                transaction_root.display()
            ))
        })?;
    temporary
        .as_file()
        .set_permissions(Permissions::from_mode(REGISTRY_MODE))
        .map_err(|error| registry_error(format!("set binary claim registry mode: {error}")))?;
    temporary.write_all(&bytes).map_err(|error| {
        registry_error(format!(
            "write binary claim registry {}: {error}",
            path.display()
        ))
    })?;
    temporary.flush().map_err(|error| {
        registry_error(format!(
            "flush binary claim registry {}: {error}",
            path.display()
        ))
    })?;
    validate_open_registry(temporary.as_file(), temporary.path())?;
    temporary.as_file().sync_all().map_err(|error| {
        registry_error(format!(
            "sync binary claim registry {}: {error}",
            path.display()
        ))
    })?;
    temporary.persist(&path).map_err(|error| {
        registry_error(format!(
            "persist binary claim registry {}: {}",
            path.display(),
            error.error
        ))
    })?;
    validate_registry_destination(&path)?;
    sync_directory(transaction_root)
}

fn encode_document(document: &RegistryDocument) -> Result<Vec<u8>, CliError> {
    let mut bytes = serde_json::to_vec_pretty(document)
        .map_err(|error| registry_error(format!("encode binary claim registry: {error}")))?;
    bytes.push(b'\n');
    let encoded_len = u64::try_from(bytes.len())
        .map_err(|error| registry_error(format!("measure binary claim registry: {error}")))?;
    validate_registry_size(encoded_len, Path::new(REGISTRY_FILE))?;
    Ok(bytes)
}

fn validate_registry_size(size: u64, path: &Path) -> Result<(), CliError> {
    if size > MAX_REGISTRY_BYTES {
        Err(registry_error(format!(
            "binary claim registry exceeds {MAX_REGISTRY_BYTES} bytes: {}",
            path.display()
        )))
    } else {
        Ok(())
    }
}

fn reconcile_registry_temporaries(transaction_root: &Path) -> Result<(), CliError> {
    let mut changed = false;
    for entry in fs::read_dir(transaction_root).map_err(|error| {
        registry_error(format!(
            "read binary claim registry directory {}: {error}",
            transaction_root.display()
        ))
    })? {
        let entry = entry.map_err(|error| {
            registry_error(format!("read binary claim registry temporary: {error}"))
        })?;
        if !entry
            .file_name()
            .as_bytes()
            .starts_with(REGISTRY_TEMP_PREFIX.as_bytes())
        {
            continue;
        }
        remove_registry_temporary(&entry.path())?;
        changed = true;
    }
    if changed {
        sync_directory(transaction_root)?;
    }
    Ok(())
}

fn remove_registry_temporary(path: &Path) -> Result<(), CliError> {
    let file = open_registry(path)?.ok_or_else(|| {
        registry_error(format!(
            "binary claim registry temporary disappeared: {}",
            path.display()
        ))
    })?;
    validate_open_registry(&file, path)?;
    drop(file);
    fs::remove_file(path).map_err(|error| {
        registry_error(format!(
            "remove binary claim registry temporary {}: {error}",
            path.display()
        ))
    })
}

fn open_registry(path: &Path) -> Result<Option<File>, CliError> {
    match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => Ok(Some(file)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(registry_error(format!(
            "open binary claim registry {}: {error}",
            path.display()
        ))),
    }
}

fn validate_registry_destination(path: &Path) -> Result<(), CliError> {
    if let Some(file) = open_registry(path)? {
        validate_open_registry(&file, path)?;
    }
    Ok(())
}

fn validate_open_registry(file: &File, path: &Path) -> Result<Metadata, CliError> {
    let metadata = file.metadata().map_err(|error| {
        registry_error(format!(
            "inspect binary claim registry {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.is_file() {
        return Err(registry_error(format!(
            "binary claim registry is not a regular file: {}",
            path.display()
        )));
    }
    validate_registry_metadata(&metadata, path)?;
    Ok(metadata)
}

fn validate_registry_metadata(metadata: &Metadata, path: &Path) -> Result<(), CliError> {
    if metadata.uid() != trusted_uid() {
        return Err(registry_error(format!(
            "binary claim registry {} must be owned by uid {}, found uid {}",
            path.display(),
            trusted_uid(),
            metadata.uid()
        )));
    }
    if metadata.nlink() != 1 {
        return Err(registry_error(format!(
            "binary claim registry must have exactly one link: {}",
            path.display()
        )));
    }
    if metadata.mode() & 0o7777 != REGISTRY_MODE {
        return Err(registry_error(format!(
            "binary claim registry must have mode 0600: {}",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(not(test))]
const fn trusted_uid() -> u32 {
    0
}

#[cfg(test)]
fn trusted_uid() -> u32 {
    uzers::get_current_uid()
}
