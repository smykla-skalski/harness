//! Reading the GitHub OAuth client secret off disk.

use std::fmt;
use std::fs;
use std::path::Path;

use crate::error::PanelError;

/// The OAuth client secret, kept out of anything that prints itself.
#[derive(Clone, PartialEq, Eq)]
pub struct ClientSecret {
    value: String,
}

impl ClientSecret {
    #[must_use]
    pub fn expose(&self) -> &str {
        &self.value
    }

    #[cfg(test)]
    #[must_use]
    pub fn from_value_for_tests(value: impl Into<String>) -> Self {
        Self {
            value: value.into(),
        }
    }
}

/// `PanelConfig` derives `Debug` and is logged at startup, so the secret has to
/// redact itself rather than rely on every caller remembering not to print it.
impl fmt::Debug for ClientSecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ClientSecret")
            .field("value", &"<redacted>")
            .finish()
    }
}

/// Read the client secret, refusing a file anyone but its owner can read.
///
/// # Errors
/// Returns [`PanelError::Io`] when the file cannot be read and
/// [`PanelError::Config`] when it is blank or too widely readable.
pub fn read_client_secret(path: &Path) -> Result<ClientSecret, PanelError> {
    let contents = fs::read_to_string(path)
        .map_err(|error| PanelError::io("reading the GitHub client secret from", path, error))?;

    refuse_shared_permissions(path)?;

    // Operators create this file with an editor or a heredoc, both of which
    // leave a trailing newline that GitHub would reject as part of the secret.
    let value = contents.trim().to_owned();
    if value.is_empty() {
        return Err(PanelError::config(format!(
            "the GitHub client secret file {} is empty",
            path.display()
        )));
    }
    Ok(ClientSecret { value })
}

#[cfg(unix)]
fn refuse_shared_permissions(path: &Path) -> Result<(), PanelError> {
    use std::os::unix::fs::PermissionsExt;

    let metadata = fs::metadata(path)
        .map_err(|error| PanelError::io("inspecting the GitHub client secret at", path, error))?;
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(PanelError::config(format!(
            "the GitHub client secret file {} is mode {mode:04o}; it must not be readable by \
             group or other. Under systemd, pass it through LoadCredential",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(not(unix))]
fn refuse_shared_permissions(_path: &Path) -> Result<(), PanelError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use super::read_client_secret;

    #[cfg(unix)]
    fn set_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("setting the file mode");
    }

    #[test]
    fn reads_a_secret_and_drops_the_editor_newline() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("secret");
        fs::write(&path, "s3cret\n").expect("writing the secret");
        #[cfg(unix)]
        set_mode(&path, 0o600);

        let secret = read_client_secret(&path).expect("reading the secret");

        assert_eq!(secret.expose(), "s3cret");
    }

    #[test]
    fn refuses_a_blank_secret() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("secret");
        fs::write(&path, "   \n").expect("writing the secret");
        #[cfg(unix)]
        set_mode(&path, 0o600);

        let error = read_client_secret(&path).expect_err("a blank secret must be refused");

        assert!(error.to_string().contains("is empty"), "{error}");
    }

    #[test]
    fn names_the_missing_file() {
        let directory = tempfile::tempdir().expect("temp dir");

        let error = read_client_secret(&directory.path().join("absent"))
            .expect_err("a missing secret must be refused");

        assert!(error.to_string().contains("absent"), "{error}");
    }

    /// A world-readable secret is a working secret, so nothing else in the
    /// panel would ever notice it had leaked.
    #[cfg(unix)]
    #[test]
    fn refuses_a_secret_anyone_can_read() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("secret");
        fs::write(&path, "s3cret\n").expect("writing the secret");
        set_mode(&path, 0o644);

        let error = read_client_secret(&path).expect_err("a shared secret must be refused");

        assert!(error.to_string().contains("0644"), "{error}");
        assert!(error.to_string().contains("LoadCredential"), "{error}");
    }

    /// The redacted `Debug` is the only thing keeping the secret out of the
    /// startup log line that prints the whole config.
    #[test]
    fn debug_output_hides_the_secret() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("secret");
        fs::write(&path, "s3cret").expect("writing the secret");
        #[cfg(unix)]
        set_mode(&path, 0o400);

        let secret = read_client_secret(&path).expect("reading the secret");

        assert!(!format!("{secret:?}").contains("s3cret"));
    }
}
