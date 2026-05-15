use std::fs;

use gix::actor::{Signature, SignatureRef};
use gix::bstr::ByteSlice;
use gix::objs::WriteTo;
use gix::{ObjectId, objs};
use ssh_key::{HashAlg, LineEnding, PrivateKey};

use crate::errors::{CliError, CliErrorKind};
use crate::sandbox;
use crate::task_board::TaskBoardGitRuntimeProfile;

use super::signing::unsigned_commit_payload;
use super::types::{
    LocalBranchSnapshot, NativeGitTransportReason, NativeSshCommitObject, NativeSshCommitSignature,
    RestCommitSignatureBoundary,
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

pub(super) fn native_ssh_commit_object(
    snapshot: &LocalBranchSnapshot,
    tree_sha: &str,
    parent_sha: &str,
) -> Result<NativeSshCommitObject, CliError> {
    let unsigned_payload = unsigned_commit_payload(snapshot, tree_sha, parent_sha);
    let signature = ssh_commit_signature(&snapshot.profile, unsigned_payload.as_bytes())?;
    let commit = objs::Commit {
        tree: object_id_from_hex(tree_sha, "tree")?,
        parents: [object_id_from_hex(parent_sha, "parent")?]
            .into_iter()
            .collect(),
        author: actor_signature(snapshot.author.git_actor.as_str(), "author")?,
        committer: actor_signature(snapshot.committer.git_actor.as_str(), "committer")?,
        encoding: None,
        message: snapshot.commit_message.as_str().into(),
        extra_headers: vec![(
            "gpgsig".into(),
            signature.armored_signature.as_bytes().as_bstr().into(),
        )],
    };
    let mut commit_payload = Vec::new();
    commit.write_to(&mut commit_payload).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github serialize SSH-signed commit object: {error}"
        ))
    })?;
    Ok(NativeSshCommitObject {
        commit_payload,
        signature,
        unsigned_payload,
    })
}

fn object_id_from_hex(hex: &str, label: &str) -> Result<ObjectId, CliError> {
    ObjectId::from_hex(hex.as_bytes()).map_err(|error| {
        CliErrorKind::workflow_io(format!(
            "task-board github parse SSH commit {label} sha '{hex}': {error}"
        ))
        .into()
    })
}

fn actor_signature(actor: &str, label: &str) -> Result<Signature, CliError> {
    SignatureRef::from_bytes(actor.as_bytes())
        .map(Into::into)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "task-board github parse SSH commit {label}: {error}"
            ))
            .into()
        })
}

#[cfg(test)]
mod tests {
    use super::super::types::{GitHubCommitAuthorRequest, LocalCommitAuthor, LocalTreeSnapshot};
    use super::*;
    use crate::task_board::{
        TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    };

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

    #[test]
    fn native_ssh_commit_object_serializes_gpgsig_ssh_header() {
        let profile = TaskBoardGitRuntimeProfile {
            signing: TaskBoardGitSigningConfig {
                mode: TaskBoardGitSigningMode::Ssh,
                ssh_private_key: Some(ED25519_PRIVATE_KEY.into()),
                ..Default::default()
            },
            ..Default::default()
        };
        let snapshot = branch_snapshot(profile);

        let commit = native_ssh_commit_object(
            &snapshot,
            "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
            "1111111111111111111111111111111111111111",
        )
        .expect("native ssh commit object");

        assert!(!commit.unsigned_payload.contains("gpgsig"));
        assert!(
            commit
                .signature
                .armored_signature
                .contains("-----BEGIN SSH SIGNATURE-----")
        );
        let parsed = objs::CommitRef::from_bytes(&commit.commit_payload, gix::hash::Kind::Sha1)
            .expect("parse serialized commit");
        let gpgsig = parsed
            .extra_headers()
            .find("gpgsig")
            .expect("gpgsig header");
        assert!(gpgsig.contains_str("-----BEGIN SSH SIGNATURE-----"));
    }

    fn branch_snapshot(profile: TaskBoardGitRuntimeProfile) -> LocalBranchSnapshot {
        LocalBranchSnapshot {
            head_tree_sha: "4b825dc642cb6eb9a060e54bf8d69288fbee4904".into(),
            commit_message: "publish task board state".into(),
            author: commit_author(),
            committer: commit_author(),
            profile,
            existing_signature: None,
            root_tree: LocalTreeSnapshot {
                entries: Vec::new(),
            },
        }
    }

    fn commit_author() -> LocalCommitAuthor {
        LocalCommitAuthor {
            request: GitHubCommitAuthorRequest {
                name: "Harness Bot".into(),
                email: Some("bot@example.com".into()),
                date: Some("2024-03-25T18:20:00Z".into()),
            },
            git_actor: "Harness Bot <bot@example.com> 1711390800 +0000".into(),
        }
    }
}
