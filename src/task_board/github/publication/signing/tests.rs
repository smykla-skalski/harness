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
            .contains("requires configured private key")
    );
}

#[test]
fn publication_uses_configured_gpg_key_path_and_passphrase() {
    let (private_key, key_id, _fingerprint) = generated_private_key(Some("secret"));
    let tempdir = tempfile::tempdir().expect("tempdir");
    let key_path = tempdir.path().join("private.asc");
    fs::write(&key_path, private_key).expect("write private key");
    let profile = TaskBoardGitRuntimeProfile {
        signing: crate::task_board::TaskBoardGitSigningConfig {
            mode: TaskBoardGitSigningMode::Gpg,
            gpg_key_id: Some(key_id),
            gpg_private_key_path: Some(key_path.to_string_lossy().into_owned()),
            gpg_private_key_passphrase: Some("secret".into()),
            ..Default::default()
        },
        ..Default::default()
    };

    let signature = publication_signature(&profile, None, b"payload")
        .expect("configured key signs")
        .expect("signature is present");

    assert!(signature.contains("-----BEGIN PGP SIGNATURE-----"));
}

#[test]
fn publication_uses_configured_gpg_key_material_before_path() {
    let (private_key, key_id, _fingerprint) = generated_private_key(Some("secret"));
    let profile = TaskBoardGitRuntimeProfile {
        signing: crate::task_board::TaskBoardGitSigningConfig {
            mode: TaskBoardGitSigningMode::Gpg,
            gpg_key_id: Some(key_id),
            gpg_private_key_path: Some("/path/that/must/not/be/read".into()),
            gpg_private_key: Some(private_key),
            gpg_private_key_passphrase: Some("secret".into()),
            ..Default::default()
        },
        ..Default::default()
    };

    let signature = publication_signature(&profile, None, b"payload")
        .expect("configured key signs")
        .expect("signature is present");

    assert!(signature.contains("-----BEGIN PGP SIGNATURE-----"));
}

#[test]
fn publication_rejects_configured_ssh_mode_before_rest_publication() {
    let profile = TaskBoardGitRuntimeProfile {
        signing: crate::task_board::TaskBoardGitSigningConfig {
            mode: TaskBoardGitSigningMode::Ssh,
            ssh_key_path: Some("/tmp/id_sign.pub".into()),
            ..Default::default()
        },
        ..Default::default()
    };

    let boundary = rest_commit_signature_boundary(&profile, None).expect("configured ssh boundary");
    assert_eq!(
        boundary,
        RestCommitSignatureBoundary::NativeGitTransportRequired(
            NativeGitTransportReason::ConfiguredSshSigning
        )
    );

    let error =
        validate_rest_publication_signature_support(&profile, None).expect_err("ssh mode error");

    assert!(
        error
            .to_string()
            .contains("REST commit creation accepts only PGP signatures")
    );
    assert!(
        error
            .to_string()
            .contains("requires native Git object creation and transport")
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
            .contains("REST commit creation accepts only PGP signatures")
    );
}

#[test]
fn publication_rejects_existing_ssh_signature_before_rest_publication() {
    let profile = TaskBoardGitRuntimeProfile::default();

    let error =
        validate_rest_publication_signature_support(&profile, Some(&LocalCommitSignature::Ssh))
            .expect_err("ssh signature error");

    assert_eq!(
        rest_commit_signature_boundary(&profile, Some(&LocalCommitSignature::Ssh))
            .expect("ssh boundary"),
        RestCommitSignatureBoundary::NativeGitTransportRequired(
            NativeGitTransportReason::ExistingSshSignature
        )
    );

    assert!(
        error
            .to_string()
            .contains("REST commit creation accepts only PGP signatures")
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
