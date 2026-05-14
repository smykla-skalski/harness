use std::fs;
use std::io::Cursor;

use chrono::{FixedOffset, TimeZone};
use gix::actor::SignatureRef;
use pgp::composed::{ArmorOptions, Deserializable, DetachedSignature, SignedSecretKey};
use pgp::crypto::hash::HashAlgorithm;
use pgp::types::{KeyDetails, Password};
use rand::thread_rng;

use crate::errors::{CliError, CliErrorKind};
use crate::sandbox;
use crate::task_board::{TaskBoardGitRuntimeProfile, TaskBoardGitSigningMode};

use super::snapshot_error;
use super::types::{
    GitHubCommitAuthorRequest, LocalBranchSnapshot, LocalCommitAuthor, LocalCommitSignature,
};

pub(super) fn commit_author(
    signature: SignatureRef<'_>,
    override_name: Option<&str>,
    override_email: Option<&str>,
) -> Result<LocalCommitAuthor, CliError> {
    let signature = signature.trim();
    let time = signature
        .time()
        .map_err(|error| snapshot_error("parse commit author time", error))?;
    let offset = FixedOffset::east_opt(time.offset).ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "task-board github commit author timezone offset '{}' is outside supported range",
            time.offset
        )))
    })?;
    let date = offset
        .timestamp_opt(time.seconds, 0)
        .single()
        .ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "task-board github commit author timestamp '{}' is outside supported range",
                time.seconds
            )))
        })?
        .to_rfc3339();
    let name = override_name.map_or_else(
        || String::from_utf8_lossy(signature.name.as_ref()).into_owned(),
        ToOwned::to_owned,
    );
    let email = override_email.map_or_else(
        || String::from_utf8_lossy(signature.email.as_ref()).into_owned(),
        ToOwned::to_owned,
    );
    validate_git_actor_field("commit author name", name.as_str())?;
    validate_git_actor_field("commit author email", email.as_str())?;
    if email.contains(['<', '>']) {
        return Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github commit author email cannot contain angle brackets",
        )));
    }
    let git_actor = format!(
        "{name} <{email}> {} {}",
        time.seconds,
        git_timezone_offset(time.offset)
    );
    Ok(LocalCommitAuthor {
        request: GitHubCommitAuthorRequest {
            name,
            email: Some(email),
            date: Some(date),
        },
        git_actor,
    })
}

pub(super) fn unsigned_commit_payload(
    snapshot: &LocalBranchSnapshot,
    tree_sha: &str,
    parent_sha: &str,
) -> String {
    format!(
        "tree {tree_sha}\nparent {parent_sha}\nauthor {author}\ncommitter {committer}\n\n{message}",
        author = snapshot.author.git_actor,
        committer = snapshot.committer.git_actor,
        message = snapshot.commit_message,
    )
}

pub(super) fn local_commit_signature(
    commit: &gix::Commit<'_>,
) -> Result<Option<LocalCommitSignature>, CliError> {
    let Some((signature, _signed_data)) = commit
        .signature()
        .map_err(|error| snapshot_error("read HEAD signature", error))?
    else {
        return Ok(None);
    };
    let signature = String::from_utf8_lossy(signature.as_ref()).into_owned();
    if signature.contains("-----BEGIN SSH SIGNATURE-----") {
        return Ok(Some(LocalCommitSignature::Ssh));
    }
    if signature.contains("-----BEGIN PGP SIGNATURE-----") {
        return Ok(Some(LocalCommitSignature::Pgp(signature)));
    }
    Ok(Some(LocalCommitSignature::Unsupported))
}

pub(super) fn publication_signature(
    profile: &TaskBoardGitRuntimeProfile,
    signature: Option<&LocalCommitSignature>,
    payload: &[u8],
) -> Result<Option<String>, CliError> {
    if profile.signing.mode == TaskBoardGitSigningMode::Gpg {
        if let Some(signature) = configured_gpg_signature(profile, payload)? {
            return Ok(Some(signature));
        }
        if let Some(LocalCommitSignature::Pgp(signature)) = signature {
            return Ok(Some(signature.clone()));
        }
        return Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github GPG signing requires a configured private key path or an existing local PGP signature",
        )));
    }
    match (profile.signing.mode, signature) {
        (TaskBoardGitSigningMode::None, None) => Ok(None),
        (TaskBoardGitSigningMode::None, Some(LocalCommitSignature::Pgp(signature))) => {
            Ok(Some(signature.clone()))
        }
        (TaskBoardGitSigningMode::Gpg, _) => unreachable!("GPG signing handled before match"),
        (TaskBoardGitSigningMode::Ssh, _) | (_, Some(LocalCommitSignature::Ssh)) => {
            Err(CliError::from(CliErrorKind::workflow_io(
                "task-board github SSH-signed commits require native Git transport; the GitHub REST commit API only supports PGP signatures",
            )))
        }
        (_, Some(LocalCommitSignature::Unsupported)) => {
            Err(CliError::from(CliErrorKind::workflow_io(
                "task-board github commit contains an unsupported signature type",
            )))
        }
    }
}

fn validate_git_actor_field(label: &str, value: &str) -> Result<(), CliError> {
    if value.contains(['\n', '\r']) {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "task-board github {label} cannot contain newlines"
        ))));
    }
    Ok(())
}

fn git_timezone_offset(offset: i32) -> String {
    let sign = if offset < 0 { '-' } else { '+' };
    let absolute = i64::from(offset).abs();
    let hours = absolute / 3600;
    let minutes = (absolute % 3600) / 60;
    format!("{sign}{hours:02}{minutes:02}")
}

fn configured_gpg_signature(
    profile: &TaskBoardGitRuntimeProfile,
    payload: &[u8],
) -> Result<Option<String>, CliError> {
    let Some(private_key_path) = profile.signing.gpg_private_key_path.as_deref() else {
        return Ok(None);
    };
    let key_scope = sandbox::resolve_path_input(private_key_path)?;
    let private_key = fs::read_to_string(key_scope.path()).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github read configured GPG private key {}: {error}",
            key_scope.path().display()
        ))
    })?;
    Ok(Some(pgp_detached_signature(
        private_key.as_str(),
        profile.signing.gpg_key_id.as_deref(),
        profile.signing.gpg_private_key_passphrase.as_deref(),
        payload,
    )?))
}

fn pgp_detached_signature(
    armored_private_key: &str,
    expected_key_id: Option<&str>,
    passphrase: Option<&str>,
    payload: &[u8],
) -> Result<String, CliError> {
    let (private_key, _) = SignedSecretKey::from_string(armored_private_key).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github parse configured GPG private key: {error}"
        ))
    })?;
    validate_configured_key_id(&private_key, expected_key_id)?;
    let password = passphrase.map_or_else(Password::empty, Password::from);
    let signature = DetachedSignature::sign_binary_data(
        thread_rng(),
        &private_key.primary_key,
        &password,
        HashAlgorithm::Sha256,
        Cursor::new(payload),
    )
    .map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github sign commit with GPG key: {error}"
        ))
    })?;
    signature
        .to_armored_string(ArmorOptions::default())
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("task-board github armor GPG signature: {error}"))
                .into()
        })
}

fn validate_configured_key_id(
    private_key: &SignedSecretKey,
    expected_key_id: Option<&str>,
) -> Result<(), CliError> {
    let Some(expected_key_id) = normalize_gpg_key_id(expected_key_id) else {
        return Ok(());
    };
    let legacy_key_id = format!("{}", private_key.primary_key.legacy_key_id());
    let fingerprint = format!("{:x}", private_key.primary_key.fingerprint());
    if expected_key_id == legacy_key_id || expected_key_id == fingerprint {
        return Ok(());
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "task-board github configured GPG key id '{expected_key_id}' does not match private key '{legacy_key_id}' or fingerprint '{fingerprint}'"
    ))))
}

fn normalize_gpg_key_id(key_id: Option<&str>) -> Option<String> {
    key_id
        .map(|key_id| {
            key_id
                .trim()
                .strip_prefix("0x")
                .or_else(|| key_id.trim().strip_prefix("0X"))
                .unwrap_or_else(|| key_id.trim())
                .chars()
                .filter(|ch| !ch.is_ascii_whitespace())
                .collect::<String>()
                .to_ascii_lowercase()
        })
        .filter(|key_id| !key_id.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use pgp::composed::{KeyType, SecretKeyParamsBuilder};

    #[test]
    fn publication_preserves_existing_pgp_signature() {
        let signature = "-----BEGIN PGP SIGNATURE-----\nbody\n-----END PGP SIGNATURE-----";
        let profile = TaskBoardGitRuntimeProfile {
            signing: crate::task_board::TaskBoardGitSigningConfig {
                mode: TaskBoardGitSigningMode::Gpg,
                ..Default::default()
            },
            ..Default::default()
        };

        let result = publication_signature(
            &profile,
            Some(&LocalCommitSignature::Pgp(signature.into())),
            b"payload",
        )
        .expect("publication signature");

        assert_eq!(result.as_deref(), Some(signature));
    }

    #[test]
    fn publication_rejects_gpg_mode_without_existing_signature() {
        let profile = TaskBoardGitRuntimeProfile {
            signing: crate::task_board::TaskBoardGitSigningConfig {
                mode: TaskBoardGitSigningMode::Gpg,
                ..Default::default()
            },
            ..Default::default()
        };

        let error =
            publication_signature(&profile, None, b"payload").expect_err("missing signature error");

        assert!(
            error
                .to_string()
                .contains("requires a configured private key path")
        );
    }

    #[test]
    fn publication_rejects_ssh_signature_on_rest_path() {
        let profile = TaskBoardGitRuntimeProfile::default();
        let error = publication_signature(&profile, Some(&LocalCommitSignature::Ssh), b"payload")
            .expect_err("ssh signature error");

        assert!(
            error
                .to_string()
                .contains("SSH-signed commits require native Git transport")
        );
    }

    #[test]
    fn configured_gpg_signature_validates_configured_key_id() {
        let (private_key, key_id, fingerprint) = generated_private_key(None);

        let signature = pgp_detached_signature(
            private_key.as_str(),
            Some(key_id.to_ascii_uppercase().as_str()),
            None,
            b"payload",
        )
        .expect("matching key id signs");
        assert!(signature.contains("-----BEGIN PGP SIGNATURE-----"));

        pgp_detached_signature(
            private_key.as_str(),
            Some(fingerprint.as_str()),
            None,
            b"payload",
        )
        .expect("matching fingerprint signs");

        let error = pgp_detached_signature(
            private_key.as_str(),
            Some("0000000000000000"),
            None,
            b"payload",
        )
        .expect_err("mismatched key id should fail");
        assert!(error.to_string().contains("does not match private key"));
    }

    #[test]
    fn configured_gpg_signature_uses_private_key_passphrase() {
        let (private_key, key_id, _fingerprint) = generated_private_key(Some("secret"));

        let error = pgp_detached_signature(
            private_key.as_str(),
            Some(key_id.as_str()),
            Some("wrong"),
            b"payload",
        )
        .expect_err("wrong passphrase should fail");
        assert!(error.to_string().contains("sign commit with GPG key"));

        let signature = pgp_detached_signature(
            private_key.as_str(),
            Some(key_id.as_str()),
            Some("secret"),
            b"payload",
        )
        .expect("configured passphrase signs");
        assert!(signature.contains("-----BEGIN PGP SIGNATURE-----"));
    }

    fn generated_private_key(passphrase: Option<&str>) -> (String, String, String) {
        let mut builder = SecretKeyParamsBuilder::default();
        builder
            .key_type(KeyType::Ed25519Legacy)
            .can_certify(false)
            .can_sign(true)
            .primary_user_id("Harness Bot <bot@example.com>".into())
            .passphrase(passphrase.map(ToOwned::to_owned));
        let key = builder
            .build()
            .expect("build secret key params")
            .generate(thread_rng())
            .expect("generate secret key");
        let key_id = format!("{}", key.primary_key.legacy_key_id());
        let fingerprint = format!("{:x}", key.primary_key.fingerprint());
        let armored = key
            .to_armored_string(ArmorOptions::default())
            .expect("armor private key");
        (armored, key_id, fingerprint)
    }
}
