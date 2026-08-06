use std::sync::{Arc, Mutex, MutexGuard};

use harness_kernel::errors::{CliError, CliErrorKind};

pub type Shared<T> = Arc<Mutex<T>>;

/// Lock a mutex, mapping a poison error to a workflow I/O `CliError`.
///
/// # Errors
/// Returns a workflow I/O error when the mutex is poisoned.
pub fn lock<'a, T>(mutex: &'a Mutex<T>, name: &str) -> Result<MutexGuard<'a, T>, CliError> {
    mutex
        .lock()
        .map_err(|error| CliErrorKind::workflow_io(format!("{name} lock poisoned: {error}")).into())
}

/// Persist newly captured transcript bytes without rewriting the full file.
///
/// # Errors
/// Returns a workflow I/O error when creating the parent directory or
/// writing the transcript fails.
pub fn persist_transcript(
    path: &std::path::Path,
    transcript: &[u8],
    persisted_len: &mut usize,
) -> Result<(), CliError> {
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).map_err(|error| {
            CliErrorKind::workflow_io(format!("create terminal agent transcript dir: {error}"))
        })?;
    }

    if transcript.len() < *persisted_len {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
        })?;
        *persisted_len = transcript.len();
        return Ok(());
    }

    if transcript.len() == *persisted_len {
        if *persisted_len == 0 && !path.exists() {
            fs_err::write(path, transcript).map_err(|error| {
                CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
            })?;
        }
        return Ok(());
    }

    if *persisted_len == 0 || !path.exists() {
        fs_err::write(path, transcript).map_err(|error| {
            CliErrorKind::workflow_io(format!("write terminal agent transcript: {error}"))
        })?;
    } else {
        use std::io::Write;

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
    }

    *persisted_len = transcript.len();
    Ok(())
}
