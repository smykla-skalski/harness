use std::fs;

use ssh_key::{HashAlg, LineEnding, PrivateKey};

use crate::errors::{CliError, CliErrorKind};
use crate::sandbox;
use crate::task_board::TaskBoardGitRuntimeProfile;

use super::types::{
    NativeGitTransportReason, NativeSshCommitSignature, RestCommitSignatureBoundary,
};

const GIT_SSHSIG_NAMESPACE: &str = "git";

pub(super) fn ssh_commit_signature(
    profile: &TaskBoardGitRuntimeProfile,
    payload: &[u8],
) -> Result<NativeSshCommitSignature, CliError> {
    let private_key_material = ssh_private_key_material(profile)?;
    let private_key = parse_ssh_private_key(
        private_key_material.as_str(),
        profile.signing.ssh_private_key_passphrase.as_deref(),
    )?;
    let signature = private_key
        .sign(GIT_SSHSIG_NAMESPACE, HashAlg::Sha512, payload)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "task-board github sign commit payload with SSH key: {error}"
            ))
        })?
        .to_pem(LineEnding::LF)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("task-board github armor SSH signature: {error}"))
        })?;

    Ok(NativeSshCommitSignature {
        armored_signature: signature,
        rest_boundary: RestCommitSignatureBoundary::NativeGitTransportRequired(
            NativeGitTransportReason::ConfiguredSshSigning,
        ),
    })
}

fn ssh_private_key_material(profile: &TaskBoardGitRuntimeProfile) -> Result<String, CliError> {
    if let Some(private_key) = profile.signing.ssh_private_key.as_deref() {
        return Ok(private_key.to_owned());
    }
    let Some(private_key_path) = profile.signing.ssh_key_path.as_deref() else {
        return Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github SSH signing requires configured private key material or path",
        )));
    };
    let key_scope = sandbox::resolve_path_input(private_key_path)?;
    fs::read_to_string(key_scope.path()).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github read configured SSH private key {}: {error}",
            key_scope.path().display()
        ))
        .into()
    })
}

fn parse_ssh_private_key(
    private_key_material: &str,
    passphrase: Option<&str>,
) -> Result<PrivateKey, CliError> {
    let private_key = PrivateKey::from_openssh(private_key_material).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github parse configured SSH private key: {error}"
        ))
    })?;
    if !private_key.is_encrypted() {
        return Ok(private_key);
    }
    let Some(passphrase) = passphrase else {
        return Err(CliError::from(CliErrorKind::workflow_io(
            "task-board github encrypted SSH private key requires a passphrase",
        )));
    };
    private_key.decrypt(passphrase).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github decrypt configured SSH private key: {error}"
        ))
        .into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::{TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig};

    const ED25519_PRIVATE_KEY: &str = r#"
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCzPq7zfqLffKoBDe/eo04kH2XxtSmk9D7RQyf1xUqrYgAAAJgAIAxdACAM
XQAAAAtzc2gtZWQyNTUxOQAAACCzPq7zfqLffKoBDe/eo04kH2XxtSmk9D7RQyf1xUqrYg
AAAEC2BsIi0QwW2uFscKTUUXNHLsYX4FxlaSDSblbAj7WR7bM+rvN+ot98qgEN796jTiQf
ZfG1KaT0PtFDJ/XFSqtiAAAAEHVzZXJAZXhhbXBsZS5jb20BAgMEBQ==
-----END OPENSSH PRIVATE KEY-----
"#;

    #[test]
    fn ssh_commit_payload_signature_uses_direct_key_material() {
        let profile = TaskBoardGitRuntimeProfile {
            signing: TaskBoardGitSigningConfig {
                ssh_private_key: Some(ED25519_PRIVATE_KEY.into()),
                ..Default::default()
            },
            ..Default::default()
        };

        let signature =
            ssh_commit_signature(&profile, b"tree abc\n\nmessage").expect("ssh signature");

        assert!(
            signature
                .armored_signature
                .contains("-----BEGIN SSH SIGNATURE-----")
        );
        assert_eq!(
            signature.rest_boundary,
            RestCommitSignatureBoundary::NativeGitTransportRequired(
                NativeGitTransportReason::ConfiguredSshSigning
            )
        );
    }

    #[test]
    fn ssh_commit_payload_signature_prefers_direct_key_material_over_path() {
        let profile = TaskBoardGitRuntimeProfile {
            signing: TaskBoardGitSigningConfig {
                ssh_key_path: Some("/path/that/must/not/be/read".into()),
                ssh_private_key: Some(ED25519_PRIVATE_KEY.into()),
                ..Default::default()
            },
            ..Default::default()
        };

        let signature = ssh_commit_signature(&profile, b"payload").expect("ssh signature");

        assert!(
            signature
                .armored_signature
                .contains("-----BEGIN SSH SIGNATURE-----")
        );
    }

    #[test]
    fn ssh_commit_payload_signature_requires_key_material_or_path() {
        let error = ssh_commit_signature(&TaskBoardGitRuntimeProfile::default(), b"payload")
            .expect_err("missing ssh key");

        assert!(
            error
                .to_string()
                .contains("requires configured private key material or path")
        );
    }
}
