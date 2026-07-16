use std::io::Write as _;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::errors::{CliError, CliErrorKind};

pub(super) type Shared<T> = Arc<Mutex<T>>;

pub(super) fn lock<'a, T>(mutex: &'a Mutex<T>, name: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("{name} lock poisoned: {error}")).into())
}

pub(super) fn persist_transcript(
    path: &Path,
    transcript: &[u8],
    persisted_len: &mut usize,
) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!("create terminal agent transcript dir: {error}"))
        })?;
    }
    if transcript.len() < *persisted_len || *persisted_len == 0 || !path.exists() {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
        })?;
    } else if transcript.len() > *persisted_len {
        let mut file = fs_err::OpenOptions::new()
            .append(true)
            .create(true)
            .open(path)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("open terminal agent transcript: {error}"))
            })?;
        file.write_all(&transcript[*persisted_len..])
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("append terminal agent transcript: {error}"))
            })?;
    } else if transcript.is_empty() && !path.exists() {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
        })?;
    }
    *persisted_len = transcript.len();
    Ok(())
}
