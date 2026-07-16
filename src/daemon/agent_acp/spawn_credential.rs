use std::io;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use crate::errors::{CliError, CliErrorKind};

const OPENROUTER_TEMP_PREFIX: &str = "harness-openrouter-";
const OPENROUTER_KEY_FILE: &str = "api-key";

/// Owns a one-shot spawn credential until protocol initialization completes.
///
/// Dropping this guard removes both the credential file and its private
/// directory, including on spawn, transport, or initialization failures.
pub(super) struct SpawnCredential {
    directory: TempDir,
}

impl SpawnCredential {
    pub(super) fn openrouter(token: &str) -> Result<Self, CliError> {
        let directory = tempfile::Builder::new()
            .prefix(OPENROUTER_TEMP_PREFIX)
            .tempdir()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("create openrouter credential tempdir: {error}"))
            })?;
        let path = directory.path().join(OPENROUTER_KEY_FILE);
        write_credential_bytes(&path, token).map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "write openrouter credential file `{}`: {error}",
                path.display()
            ))
        })?;
        Ok(Self { directory })
    }

    pub(super) fn path(&self) -> PathBuf {
        self.directory.path().join(OPENROUTER_KEY_FILE)
    }
}

pub(super) fn release_after_initialization<T, E>(
    result: Result<T, E>,
    credential: Option<SpawnCredential>,
) -> Result<T, E> {
    drop(credential);
    result
}

#[cfg(unix)]
fn write_credential_bytes(path: &Path, token: &str) -> io::Result<()> {
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(token.as_bytes())?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_credential_bytes(path: &Path, token: &str) -> io::Result<()> {
    std::fs::write(path, token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_guard_removes_file_and_directory() {
        let credential = SpawnCredential::openrouter("sk-one-shot").expect("credential");
        let path = credential.path();
        let directory = path.parent().expect("credential directory").to_path_buf();
        assert_eq!(
            std::fs::read_to_string(&path).expect("read key"),
            "sk-one-shot"
        );

        drop(credential);

        assert!(!path.exists());
        assert!(!directory.exists());
    }

    #[test]
    fn initialization_error_releases_credential_guard() {
        let credential = SpawnCredential::openrouter("sk-failed-init").expect("credential");
        let path = credential.path();
        let directory = path.parent().expect("credential directory").to_path_buf();

        let result: Result<(), &str> =
            release_after_initialization(Err("initialize failed"), Some(credential));

        assert_eq!(result, Err("initialize failed"));
        assert!(!path.exists());
        assert!(!directory.exists());
    }

    #[tokio::test]
    async fn aborted_protocol_task_releases_credential_guard() {
        let credential = SpawnCredential::openrouter("sk-aborted-init").expect("credential");
        let path = credential.path();
        let directory = path.parent().expect("credential directory").to_path_buf();
        let task = tokio::spawn(async move {
            std::future::pending::<()>().await;
            drop(credential);
        });

        task.abort();
        let error = task.await.expect_err("task should be cancelled");

        assert!(error.is_cancelled());
        assert!(!path.exists());
        assert!(!directory.exists());
    }

    #[cfg(unix)]
    #[test]
    fn credential_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt as _;

        let credential = SpawnCredential::openrouter("sk-private").expect("credential");
        let mode = std::fs::metadata(credential.path())
            .expect("credential metadata")
            .permissions()
            .mode()
            & 0o777;

        assert_eq!(mode, 0o600);
    }
}
