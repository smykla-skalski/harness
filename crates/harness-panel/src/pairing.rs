//! Claiming the credential the panel mints with.
//!
//! A separate step from serving, run once by an operator. Keeping it out of
//! `serve` is deliberate: a one-time code left in a unit file would be spent on
//! the first start and refused on every restart afterwards, and a panel that
//! treated that as fatal would take sign-in down with it. Serving never claims,
//! so there is nothing to leave behind.

use std::fs;
use std::path::Path;

use chrono::Utc;

use crate::config::PanelConfig;
use crate::config::daemon::BROKER_ROLE;
use crate::daemon_client::{DaemonClient, DaemonCredential};
use crate::error::PanelError;
use crate::store::Store;
use uuid::Uuid;

/// Claim a broker credential and store it, replacing any earlier one.
///
/// Re-pairing keeps the existing daemon client id. The daemon uses that id as
/// the owner of every pairing the broker minted, so changing it would hide
/// still-active devices from the replacement credential.
///
/// # Errors
/// Returns [`PanelError::Io`] or [`PanelError::Config`] when the code file
/// cannot be read or is too widely readable, [`PanelError::Daemon`] when the
/// daemon refuses the code or issues the wrong role, and
/// [`PanelError::Storage`] when the credential cannot be kept.
pub async fn claim(config: &PanelConfig, code_file: &Path) -> Result<(), PanelError> {
    let code = read_pair_code(code_file)?;
    let store = Store::open(&config.state_dir).await?;
    let client = DaemonClient::new(&config.daemon)?;

    let client_id = client_id_for_claim(&store).await?;
    let credential = client.claim(&code, &client_id).await?;

    refuse_wrong_role(&credential)?;
    keep(&store, &credential).await
}

async fn client_id_for_claim(store: &Store) -> Result<String, PanelError> {
    Ok(store.daemon_credential().await?.map_or_else(
        || Uuid::new_v4().to_string(),
        |credential| credential.client_id,
    ))
}

/// A credential of the wrong role stores happily and then fails for whoever
/// first tries to generate a link, long after the operator has moved on from
/// the code they pasted.
fn refuse_wrong_role(credential: &DaemonCredential) -> Result<(), PanelError> {
    if credential.role == BROKER_ROLE {
        return Ok(());
    }
    Err(PanelError::daemon(format!(
        // The flag and the role are spelled differently, so the message says so
        // rather than leaving an operator to wonder whether it names two things.
        "the code claimed a {} credential, not {BROKER_ROLE}; create the pairing with \
         --role pairing-broker, which the daemon records as {BROKER_ROLE}. Revoke client \
         {} on the daemon, it is now orphaned",
        credential.role, credential.client_id
    )))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn keep(store: &Store, credential: &DaemonCredential) -> Result<(), PanelError> {
    store
        .store_daemon_credential(credential, Utc::now())
        .await
        .map_err(|error| {
            // The code is spent and the token existed only in memory, so the
            // client id is the one thing that makes the orphan recoverable.
            PanelError::daemon(format!(
                "claimed client {} but could not store it: {error}. Revoke that client on the \
                 daemon and claim a fresh code",
                credential.client_id
            ))
        })?;

    tracing::info!(
        client_id = %credential.client_id,
        role = %credential.role,
        "panel claimed a daemon credential"
    );
    Ok(())
}

/// Read the one-time code, refusing a file anyone but its owner can read.
///
/// A file rather than a flag, for the same reason the GitHub client secret is
/// one: a flag value and an environment string are both readable out of
/// `/proc` by any local process, and whoever reads this code first can spend it
/// and hold a credential that mints links for identities they choose.
fn read_pair_code(path: &Path) -> Result<String, PanelError> {
    refuse_shared_permissions(path)?;

    let contents = fs::read_to_string(path)
        .map_err(|error| PanelError::io("reading the daemon pairing code from", path, error))?;
    let code = contents.trim().to_owned();
    if code.is_empty() {
        return Err(PanelError::config(format!(
            "the daemon pairing code file {} is empty",
            path.display()
        )));
    }
    Ok(code)
}

#[cfg(unix)]
fn refuse_shared_permissions(path: &Path) -> Result<(), PanelError> {
    use std::os::unix::fs::PermissionsExt;

    let metadata = fs::metadata(path)
        .map_err(|error| PanelError::io("inspecting the daemon pairing code at", path, error))?;
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        return Err(PanelError::config(format!(
            "the daemon pairing code file {} is mode {mode:04o}; it must not be readable by group \
             or other",
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

    use super::{
        BROKER_ROLE, DaemonCredential, client_id_for_claim, read_pair_code, refuse_wrong_role,
    };
    use crate::store::Store;
    use uuid::Uuid;

    #[cfg(unix)]
    fn set_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("setting the file mode");
    }

    #[test]
    fn reads_a_code_and_drops_the_editor_newline() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("code");
        fs::write(&path, "pair-code\n").expect("writing the code");
        #[cfg(unix)]
        set_mode(&path, 0o600);

        assert_eq!(read_pair_code(&path).expect("reading"), "pair-code");
    }

    /// The code is a credential in transit: whoever reads it first can spend it
    /// and hold a credential that mints links for identities they choose.
    #[cfg(unix)]
    #[test]
    fn refuses_a_code_anyone_can_read_before_reading_it() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("code");
        fs::write(&path, "pair-code").expect("writing the code");
        set_mode(&path, 0o644);

        let error = read_pair_code(&path).expect_err("a shared code must be refused");

        assert!(error.to_string().contains("0644"), "{error}");
        assert!(
            !error
                .to_string()
                .contains("reading the daemon pairing code"),
            "the file must not have been read: {error}"
        );
    }

    /// The code is spent by the time this runs and the token only ever existed
    /// in memory, so the client id in the message is the whole of what an
    /// operator has to revoke the credential they cannot use. The flag spelling
    /// differs from the role the daemon records, and both belong here because
    /// one is what they type and the other is what they will read back.
    #[test]
    fn refusing_the_wrong_role_says_how_to_recover_from_it() {
        let error = refuse_wrong_role(&DaemonCredential {
            client_id: "panel-7".to_owned(),
            token: "unusable".to_owned(),
            role: "operator".to_owned(),
        })
        .expect_err("a credential that cannot mint must be refused");
        let message = error.to_string();

        assert!(message.contains("panel-7"), "{message}");
        assert!(message.contains("--role pairing-broker"), "{message}");
        assert!(message.contains(BROKER_ROLE), "{message}");
        assert!(
            !message.contains("unusable"),
            "the token must not leak: {message}"
        );
    }

    #[test]
    fn a_broker_credential_is_accepted() {
        refuse_wrong_role(&DaemonCredential {
            client_id: "panel-7".to_owned(),
            token: "usable".to_owned(),
            role: BROKER_ROLE.to_owned(),
        })
        .expect("the role the panel needs");
    }

    #[tokio::test]
    async fn re_pairing_reuses_the_stored_daemon_client_id() {
        let store = Store::open_in_memory().await.expect("store");
        store
            .store_daemon_credential(
                &DaemonCredential {
                    client_id: "panel-stable".to_owned(),
                    token: "revoked-token".to_owned(),
                    role: BROKER_ROLE.to_owned(),
                },
                chrono::Utc::now(),
            )
            .await
            .expect("old credential");

        assert_eq!(
            client_id_for_claim(&store).await.expect("client id"),
            "panel-stable"
        );
    }

    #[tokio::test]
    async fn first_pairing_generates_a_daemon_client_id() {
        let store = Store::open_in_memory().await.expect("store");
        let client_id = client_id_for_claim(&store).await.expect("client id");

        Uuid::parse_str(&client_id).expect("generated UUID");
    }

    #[test]
    fn refuses_a_blank_code() {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("code");
        fs::write(&path, "  \n").expect("writing the code");
        #[cfg(unix)]
        set_mode(&path, 0o600);

        let error = read_pair_code(&path).expect_err("a blank code must be refused");

        assert!(error.to_string().contains("is empty"), "{error}");
    }

    #[test]
    fn names_the_missing_file() {
        let directory = tempfile::tempdir().expect("temp dir");

        let error =
            read_pair_code(&directory.path().join("absent")).expect_err("a missing code fails");

        assert!(error.to_string().contains("absent"), "{error}");
    }
}
