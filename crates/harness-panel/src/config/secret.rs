//! Reading panel secrets off disk.

#[cfg(unix)]
use std::env;
use std::fmt;
#[cfg(unix)]
use std::fs::OpenOptions;
use std::fs::{File, Metadata};
use std::io::{self, Read as _};
use std::path::Path;
#[cfg(unix)]
use std::path::PathBuf;

use sha2::{Digest, Sha256};

use crate::error::PanelError;

const MIN_COMPANION_AUTH_TOKEN_BYTES: usize = 32;
const MAX_CREDENTIAL_BYTES: u64 = 64 * 1024;

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

/// The one-way verifier for the daemon-to-panel bearer credential.
///
/// Keeping only the digest means request handling cannot accidentally log or
/// otherwise expose the token that systemd placed in the process at startup.
#[derive(Clone, PartialEq, Eq)]
pub struct CompanionAuthDigest {
    digest: [u8; 32],
}

impl CompanionAuthDigest {
    #[must_use]
    pub fn matches(&self, presented: &[u8]) -> bool {
        let presented = Sha256::digest(presented);
        presented
            .iter()
            .zip(self.digest)
            .fold(0_u8, |difference, (left, right)| {
                difference | (*left ^ right)
            })
            == 0
    }
}

impl fmt::Debug for CompanionAuthDigest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CompanionAuthDigest")
            .field("digest", &"<redacted>")
            .finish()
    }
}

/// Read the client secret, refusing a file anyone but its owner can read.
///
/// # Errors
/// Returns [`PanelError::Io`] when the file cannot be read and
/// [`PanelError::Config`] when it is blank or too widely readable.
pub fn read_client_secret(path: &Path) -> Result<ClientSecret, PanelError> {
    let contents = read_private_credential(
        path,
        "GitHub client secret",
        "reading the GitHub client secret from",
    )?;

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

/// Read and hash the private credential the daemon presents to the panel.
///
/// # Errors
/// Returns [`PanelError::Io`] when the file cannot be read and
/// [`PanelError::Config`] when the file is shared, too short, or cannot be
/// placed safely in an HTTP authorization header.
pub fn read_companion_auth_token(path: &Path) -> Result<CompanionAuthDigest, PanelError> {
    let contents = read_private_credential(
        path,
        "companion auth token",
        "reading the companion auth token from",
    )?;
    let value = contents.trim();
    if value.len() < MIN_COMPANION_AUTH_TOKEN_BYTES {
        return Err(PanelError::config(format!(
            "the companion auth token file {} must contain at least \
             {MIN_COMPANION_AUTH_TOKEN_BYTES} bytes",
            path.display()
        )));
    }
    if !value.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(PanelError::config(format!(
            "the companion auth token file {} contains whitespace, control, or header-unsafe \
             characters",
            path.display()
        )));
    }

    Ok(CompanionAuthDigest {
        digest: Sha256::digest(value.as_bytes()).into(),
    })
}

fn read_private_credential(
    path: &Path,
    label: &str,
    read_action: &'static str,
) -> Result<String, PanelError> {
    let file =
        open_private_credential(path).map_err(|error| PanelError::io(read_action, path, error))?;
    let metadata = file
        .metadata()
        .map_err(|error| PanelError::io("inspecting an open panel credential at", path, error))?;
    if !metadata.is_file() {
        return Err(PanelError::config(format!(
            "the {label} file {} must be a regular file",
            path.display()
        )));
    }
    refuse_shared_permissions(path, label, &metadata)?;

    let mut contents = String::new();
    file.take(MAX_CREDENTIAL_BYTES + 1)
        .read_to_string(&mut contents)
        .map_err(|error| PanelError::io(read_action, path, error))?;
    if contents.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err(PanelError::config(format!(
            "the {label} file {} exceeds the maximum of {MAX_CREDENTIAL_BYTES} bytes",
            path.display()
        )));
    }
    Ok(contents)
}

#[cfg(unix)]
fn open_private_credential(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt as _;

    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(not(unix))]
fn open_private_credential(path: &Path) -> io::Result<File> {
    File::open(path)
}

#[cfg(unix)]
fn refuse_shared_permissions(
    path: &Path,
    label: &str,
    metadata: &Metadata,
) -> Result<(), PanelError> {
    use std::os::unix::fs::MetadataExt as _;

    let mode = metadata.mode() & 0o777;
    let credential_directory = env::var_os("CREDENTIALS_DIRECTORY").map(PathBuf::from);
    if !credential_permissions_are_safe(path, mode, metadata.uid(), credential_directory.as_deref())
    {
        return Err(PanelError::config(format!(
            "the {label} file {} is mode {mode:04o}; it must be private or a root-owned direct \
             child of the protected systemd credential directory created by LoadCredential",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(unix)]
fn credential_permissions_are_safe(
    path: &Path,
    mode: u32,
    owner_uid: u32,
    credential_directory: Option<&Path>,
) -> bool {
    let private_to_owner = mode.trailing_zeros() >= 6;
    let safe_systemd_acl = owner_uid == 0
        && mode.trailing_zeros() >= 5
            && credential_directory.is_some_and(|directory| {
                directory.is_absolute()
                    && path.parent() == Some(directory)
                    && path.file_name().is_some()
            });
    private_to_owner || safe_systemd_acl
}

#[cfg(not(unix))]
fn refuse_shared_permissions(
    _path: &Path,
    _label: &str,
    _metadata: &Metadata,
) -> Result<(), PanelError> {
    Ok(())
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::ffi::CString;
    use std::fs;
    #[cfg(unix)]
    use std::fs::OpenOptions;
    #[cfg(unix)]
    use std::io::{self, Write as _};
    use std::path::Path;
    #[cfg(unix)]
    use std::time::{Duration, Instant};

    #[cfg(unix)]
    use super::credential_permissions_are_safe;
    use super::{read_client_secret, read_companion_auth_token};

    #[cfg(unix)]
    fn set_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("setting the file mode");
    }

    #[cfg(unix)]
    fn try_feed_fifo(path: &Path) -> io::Result<bool> {
        use std::os::unix::fs::OpenOptionsExt as _;

        let mut writer = match OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(path)
        {
            Ok(writer) => writer,
            Err(error) if error.raw_os_error() == Some(libc::ENXIO) => return Ok(false),
            Err(error) => return Err(error),
        };
        match writer.write_all(b"0123456789abcdef0123456789abcdef") {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(true),
            Err(error) => Err(error),
        }
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
    /// panel would ever notice it had leaked. The refusal also comes before the
    /// read, so a secret this exposed never reaches the panel's memory, where a
    /// later panic or core dump could carry it further.
    #[cfg(unix)]
    #[test]
    fn refuses_a_secret_anyone_can_read_before_reading_it() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("secret");
        fs::write(&path, "s3cret\n").expect("writing the secret");
        set_mode(&path, 0o644);

        let error = read_client_secret(&path).expect_err("a shared secret must be refused");

        assert!(error.to_string().contains("0644"), "{error}");
        assert!(error.to_string().contains("LoadCredential"), "{error}");
        assert!(
            !error
                .to_string()
                .contains("reading the GitHub client secret"),
            "the file must not have been read: {error}"
        );
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

    #[test]
    fn companion_token_is_trimmed_hashed_and_redacted() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("companion-token");
        let token = "0123456789abcdef0123456789abcdef";
        fs::write(&path, format!("{token}\n")).expect("writing the token");
        #[cfg(unix)]
        set_mode(&path, 0o400);

        let digest = read_companion_auth_token(&path).expect("reading the token");

        assert!(digest.matches(token.as_bytes()));
        assert!(!digest.matches(b"0123456789abcdef0123456789abcdee"));
        assert!(!format!("{digest:?}").contains(token));
    }

    #[test]
    fn companion_token_rejects_short_or_header_unsafe_values() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("companion-token");

        for value in [
            "",
            "short",
            "0123456789abcdef 123456789abcdef",
            "0123456789abcdef\n123456789abcdef",
            "0123456789abcdef0123456789abcde\u{7f}",
            "0123456789abcdef0123456789abcdeé",
        ] {
            fs::write(&path, value).expect("writing the token");
            #[cfg(unix)]
            set_mode(&path, 0o600);

            assert!(
                read_companion_auth_token(&path).is_err(),
                "{value:?} should be refused"
            );
        }
    }

    #[test]
    fn credentials_have_a_bounded_size() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("companion-token");
        fs::write(&path, vec![b'A'; 64 * 1024 + 1]).expect("writing the token");
        #[cfg(unix)]
        set_mode(&path, 0o600);

        let error = read_companion_auth_token(&path).expect_err("oversized token must be refused");

        assert!(error.to_string().contains("65536"), "{error}");
    }

    #[cfg(unix)]
    #[test]
    fn companion_token_must_be_private() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("companion-token");
        fs::write(&path, "0123456789abcdef0123456789abcdef").expect("writing the token");
        set_mode(&path, 0o640);

        let error = read_companion_auth_token(&path).expect_err("a shared token must be refused");

        assert!(error.to_string().contains("0640"), "{error}");
        assert!(
            error.to_string().contains("companion auth token"),
            "{error}"
        );
        assert!(error.to_string().contains("systemd credential"), "{error}");
    }

    #[cfg(unix)]
    #[test]
    fn only_root_owned_direct_systemd_credentials_may_use_an_acl_mask() {
        let directory = Path::new("/run/credentials/harness-panel.service");
        let credential = directory.join("companion-auth-token");

        assert!(credential_permissions_are_safe(
            &credential,
            0o440,
            0,
            Some(directory)
        ));
        assert!(!credential_permissions_are_safe(
            &credential,
            0o440,
            501,
            Some(directory)
        ));
        assert!(!credential_permissions_are_safe(
            &directory.join("nested/token"),
            0o440,
            0,
            Some(directory)
        ));
        assert!(!credential_permissions_are_safe(
            &credential,
            0o460,
            0,
            Some(directory)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn companion_token_must_be_a_regular_file_without_waiting_on_a_fifo() {
        use std::os::unix::ffi::OsStrExt as _;
        use std::thread;

        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("companion-token");
        let raw_path = CString::new(path.as_os_str().as_bytes()).expect("FIFO path");
        // SAFETY: `raw_path` is a live, NUL-terminated pathname and the mode is valid.
        let result = unsafe { libc::mkfifo(raw_path.as_ptr(), 0o600) };
        assert_eq!(result, 0, "creating FIFO: {}", io::Error::last_os_error());

        let reader_path = path.clone();
        let reader = thread::spawn(move || read_companion_auth_token(&reader_path));
        let deadline = Instant::now() + Duration::from_secs(1);
        let mut fed_fifo = false;
        while !reader.is_finished() && Instant::now() < deadline {
            fed_fifo = try_feed_fifo(&path).expect("feeding a fallback token");
            if fed_fifo {
                break;
            }
            thread::yield_now();
        }
        assert!(
            reader.is_finished() || fed_fifo,
            "credential reader did not inspect or open the FIFO"
        );

        let error = reader
            .join()
            .expect("joining the credential reader")
            .expect_err("a FIFO must be refused");
        assert!(error.to_string().contains("regular file"), "{error}");
    }

    #[cfg(unix)]
    #[test]
    fn companion_token_refuses_a_symbolic_link() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().expect("temp dir");
        let target = directory.path().join("target");
        let path = directory.path().join("companion-token");
        fs::write(&target, "0123456789abcdef0123456789abcdef").expect("writing the token");
        set_mode(&target, 0o600);
        symlink(&target, &path).expect("linking the token");

        let error = read_companion_auth_token(&path).expect_err("a symlink must be refused");

        assert!(error.to_string().contains(&path.display().to_string()));
    }
}
