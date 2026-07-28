use super::*;

use std::os::unix::fs::symlink;

use harness_testkit::add_git_worktree;

use crate::session::storage;

/// A sandboxed daemon reads the checkout only while the folder grant is held.
/// Once the grant is gone the git read fails, and without the recorded origin
/// the checkout registers as its own repository root with no worktree status.
#[test]
fn discovered_project_for_checkout_falls_back_to_recorded_identity() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let repository = tmp.path().join("repository");
        init_git_repo(&repository);
        let worktree = tmp.path().join("feature-worktree");
        add_git_worktree(&repository, &worktree, "feature");
        storage::record_project_origin(&worktree).expect("record project origin");
        let canonical_repository = repository.canonicalize().expect("canonicalize repository");

        fs::remove_file(worktree.join(".git")).expect("drop worktree git link");
        let project = discovered_project_for_checkout(&worktree);

        assert_eq!(project.name, "repository");
        assert_eq!(
            project.repository_root.as_deref(),
            Some(canonical_repository.as_path())
        );
        assert!(project.is_worktree, "worktree status must survive");
        assert_eq!(project.worktree_name.as_deref(), Some("feature-worktree"));
        assert_eq!(project.checkout_name, "feature-worktree");
    });
}

/// The recorded checkout root can be a raw path while the repository root was
/// stored canonical, so a purely textual difference must not read as a worktree.
#[test]
fn infer_checkout_identity_ignores_non_canonical_path_differences() {
    let tmp = tempdir().expect("tempdir");
    let context_root = tmp.path().join("context");
    let repository = tmp.path().join("repository");
    fs::create_dir_all(&repository).expect("create repository dir");
    let link = tmp.path().join("repository-link");
    symlink(&repository, &link).expect("symlink repository");
    write_text(
        &context_root.join("project-origin.json"),
        &serde_json::json!({
            "recorded_from_dir": link.display().to_string(),
            "repository_root": repository
                .canonicalize()
                .expect("canonicalize repository")
                .display()
                .to_string(),
            "checkout_root": link.display().to_string(),
            "recorded_at": "2026-07-24T10:00:00Z",
        })
        .to_string(),
    );

    let identity = infer_checkout_identity(&context_root).expect("identity");

    assert!(
        !identity.is_worktree,
        "a symlinked checkout is not a worktree of itself"
    );
    assert_eq!(identity.worktree_name, None);
}

/// A plain directory has no git identity to lose; it must keep registering as
/// a directory rather than borrowing the recorded-origin shape.
#[test]
fn discovered_project_for_checkout_keeps_plain_directory_identity() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let plain = tmp.path().join("notes");
        fs::create_dir_all(&plain).expect("create plain dir");
        storage::record_project_origin(&plain).expect("record project origin");

        let project = discovered_project_for_checkout(&plain);

        assert_eq!(project.name, "notes");
        assert_eq!(project.checkout_name, "Directory");
        assert!(!project.is_worktree);
        assert_eq!(project.worktree_name, None);
    });
}
