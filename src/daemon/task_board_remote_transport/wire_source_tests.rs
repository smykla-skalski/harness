use super::wire::{
    RemoteArtifactManifest, RemoteRepositorySelector, RemoteSourceMaterial, RemoteWireError,
    test_codex_launch,
};
use super::wire_tests::{artifact, offer_request};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

#[test]
fn same_repository_initial_source_is_exact_revision_and_digest_bound() {
    let request = offer_request().seal().expect("seal same-repository source");
    request.validate().expect("valid exact-revision source");

    let mut tampered = request;
    tampered.source = RemoteSourceMaterial::repository_revision(
        "org/repo",
        "2222222222222222222222222222222222222222",
    );
    assert_eq!(
        tampered.validate(),
        Err(RemoteWireError::DigestMismatch("request_sha256"))
    );
}

#[test]
fn pr_fix_initial_source_binds_fork_branch_and_canonical_ref() {
    let mut request = offer_request();
    request.binding.workflow_kind = TaskBoardWorkflowKind::PrFix;
    request.binding.repository = "contributor/repo".into();
    request.source = RemoteSourceMaterial::repository_branch(
        "contributor/repo",
        "feature/fix",
        "1111111111111111111111111111111111111111",
    );
    let request = request.seal().expect("seal fork source");
    request.validate().expect("valid fork source");

    for mutate in [
        |source: &mut RemoteSourceMaterial| {
            let RemoteSourceMaterial::Repository { repository, .. } = source else {
                unreachable!("repository source")
            };
            *repository = "org/repo".into();
        },
        |source: &mut RemoteSourceMaterial| {
            let RemoteSourceMaterial::Repository { revision, .. } = source else {
                unreachable!("repository source")
            };
            *revision = "2222222222222222222222222222222222222222".into();
        },
        |source: &mut RemoteSourceMaterial| {
            let RemoteSourceMaterial::Repository { selector, .. } = source else {
                unreachable!("repository source")
            };
            *selector = RemoteRepositorySelector::Branch {
                branch: "feature/fix".into(),
                reference: "refs/heads/other".into(),
            };
        },
    ] {
        let mut changed = request.clone();
        mutate(&mut changed.source);
        let malformed_ref = matches!(
            &changed.source,
            RemoteSourceMaterial::Repository {
                selector: RemoteRepositorySelector::Branch { reference, .. },
                ..
            } if reference == "refs/heads/other"
        );
        // Swapping the source repository breaks its binding pairing, and a malformed
        // ref is rejected once resealed; both fail semantically before the digest.
        let repository_swapped = changed.source.repository() != changed.binding.repository.as_str();
        if malformed_ref || repository_swapped {
            changed.request_sha256.clear();
            changed = changed.seal().expect("reseal rejected fork source");
            assert_eq!(
                changed.validate(),
                Err(RemoteWireError::InvalidSourceMaterial)
            );
        } else {
            assert_eq!(
                changed.validate(),
                Err(RemoteWireError::DigestMismatch("request_sha256"))
            );
        }
    }
}

#[test]
fn repository_source_rejects_noncanonical_git_revisions_and_refs() {
    for revision in [
        "short",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "111111111111111111111111111111111111111",
    ] {
        let mut request = offer_request();
        request.source = RemoteSourceMaterial::repository_revision("org/repo", revision);
        let request = request.seal().expect("seal malformed revision");
        assert_eq!(
            request.validate(),
            Err(RemoteWireError::InvalidSourceMaterial)
        );
    }

    for branch in [
        "feature//fix",
        "feature/.hidden",
        "feature/fix.lock",
        "feature/fix.",
        "feature/fix/",
        "feature/\u{0}fix",
        "feature/\u{1f}fix",
        "feature/\u{7f}fix",
        "@",
    ] {
        let mut request = offer_request();
        request.binding.workflow_kind = TaskBoardWorkflowKind::PrFix;
        request.source = RemoteSourceMaterial::repository_branch(
            "contributor/repo",
            branch,
            "1111111111111111111111111111111111111111",
        );
        let request = request.seal().expect("seal malformed branch");
        assert_eq!(
            request.validate(),
            Err(RemoteWireError::InvalidSourceMaterial),
            "branch {branch:?}"
        );
    }
}

#[test]
fn write_follow_up_requires_bounded_manifest_backed_bundle() {
    let mut bundle = artifact("source/cycle-1.bundle", b"git bundle bytes");
    bundle.media_type = "application/x-git-bundle".into();
    let mut request = offer_request();
    request.binding.phase = TaskBoardExecutionPhase::Review;
    request.binding.action_key = "review:reviewer".into();
    request.binding.base_revision = "2222222222222222222222222222222222222222".into();
    request.launch = test_codex_launch(
        TaskBoardExecutionPhase::Review,
        &request.binding.execution_id,
        "review:reviewer",
        "Review the frozen revision.",
    );
    request.source = RemoteSourceMaterial::prior_phase_bundle(
        "org/repo",
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
        bundle.clone(),
    );
    request.artifacts = RemoteArtifactManifest {
        entries: vec![bundle],
    };
    let request = request.seal().expect("seal prior-phase source");
    request.validate().expect("valid prior-phase source");

    let mut missing = request.clone();
    missing.artifacts = RemoteArtifactManifest::default();
    missing.request_sha256.clear();
    missing = missing.seal().expect("reseal missing bundle");
    assert_eq!(
        missing.validate(),
        Err(RemoteWireError::InvalidSourceMaterial)
    );

    let mut wrong_phase = request;
    wrong_phase.binding.workflow_kind = TaskBoardWorkflowKind::Review;
    wrong_phase.request_sha256.clear();
    wrong_phase = wrong_phase.seal().expect("reseal read-only bundle");
    assert_eq!(
        wrong_phase.validate(),
        Err(RemoteWireError::InvalidSourceMaterial)
    );
}
