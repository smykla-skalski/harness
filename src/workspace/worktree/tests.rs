use std::path::Path;

use git2::{IndexAddOption, Repository, Signature, build::RepoBuilder};
use harness_testkit::{git_branches_matching, git_head_sha, init_git_repo_with_seed};
use tempfile::TempDir;

use super::*;
use crate::workspace::layout::SessionLayout;

fn init_origin_repo(tmp: &std::path::Path) {
    init_git_repo_with_seed(tmp);
}

fn commit_file(dir: &std::path::Path, path: &str, contents: &[u8], message: &str) {
    let repo = Repository::open(dir).expect("open repo");
    std::fs::write(dir.join(path), contents).unwrap();
    stage_path(&repo, Path::new(path));
    commit_head(&repo, message);
}

fn init_checkout_with_upstream_remote() -> TempDir {
    let upstream = TempDir::new().unwrap();
    Repository::init_bare(upstream.path()).expect("init bare remote");

    let seed = TempDir::new().unwrap();
    init_origin_repo(seed.path());
    let seed_repo = Repository::open(seed.path()).expect("open seed repo");
    let default_branch = current_branch_name(&seed_repo);
    let mut remote = seed_repo
        .remote(
            "upstream",
            upstream.path().to_str().expect("upstream path utf8"),
        )
        .expect("add upstream remote");
    let refspec = format!("refs/heads/{default_branch}:refs/heads/main");
    remote.push(&[refspec.as_str()], None).expect("push seed");
    Repository::open_bare(upstream.path())
        .expect("open bare upstream")
        .set_head("refs/heads/main")
        .expect("set upstream HEAD");

    let checkout = TempDir::new().unwrap();
    let mut builder = RepoBuilder::new();
    builder.remote_create(|repo, _name, url| repo.remote("upstream", url));
    builder
        .clone(
            upstream.path().to_str().expect("upstream path utf8"),
            checkout.path(),
        )
        .expect("clone checkout from upstream");
    checkout
}

fn stage_path(repo: &Repository, path: &Path) {
    let mut index = repo.index().expect("open index");
    index
        .add_all([path], IndexAddOption::DEFAULT, None)
        .expect("stage path");
    index.write().expect("write index");
}

fn commit_head(repo: &Repository, message: &str) {
    let mut index = repo.index().expect("open index");
    let tree_id = index.write_tree().expect("write tree");
    let tree = repo.find_tree(tree_id).expect("find tree");
    let signature = Signature::now("test", "test@example.com").expect("signature");
    let parents = repo
        .head()
        .ok()
        .and_then(|head| head.peel_to_commit().ok())
        .into_iter()
        .collect::<Vec<_>>();
    let parent_refs = parents.iter().collect::<Vec<_>>();
    repo.commit(
        Some("HEAD"),
        &signature,
        &signature,
        message,
        &tree,
        &parent_refs,
    )
    .expect("create commit");
}

fn current_branch_name(repo: &Repository) -> String {
    repo.head()
        .expect("repo head")
        .shorthand()
        .expect("branch shorthand")
        .to_owned()
}

#[test]
fn creates_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "abc12345".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).expect("create");
    assert!(layout.workspace().join("README.md").exists());
    assert!(layout.memory().exists());
}

#[test]
fn destroy_removes_worktree_and_branch() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "ab234567".into(),
    };
    std::fs::create_dir_all(layout.project_dir()).unwrap();
    WorktreeController::create(origin.path(), &layout, None).unwrap();
    WorktreeController::destroy(origin.path(), &layout).expect("destroy");
    assert!(!layout.workspace().exists());
    assert!(git_branches_matching(origin.path(), "harness/").is_empty());
}

/// Verify that when a post-add filesystem step fails, `create` rolls back
/// the worktree and branch so no orphans are left in the origin repo.
///
/// Injection: pre-create a regular file at `layout.memory()` so that
/// `fs::create_dir_all(memory())` fails with ENOTDIR, triggering rollback.
#[test]
fn rollback_on_memory_create_failure() {
    let origin = TempDir::new().unwrap();
    init_origin_repo(origin.path());
    let sessions = TempDir::new().unwrap();
    let layout = SessionLayout {
        sessions_root: sessions.path().into(),
        project_name: "origin".into(),
        session_id: "cd345678".into(),
    };
    std::fs::create_dir_all(layout.session_root()).unwrap();
    std::fs::write(layout.memory(), b"blocker").unwrap();

    let result = WorktreeController::create(origin.path(), &layout, None);
    assert!(
        result.is_err(),
        "expected create to fail due to blocked memory dir"
    );

    assert!(
        !layout.workspace().exists(),
        "workspace should have been removed by rollback"
    );

    assert!(
        git_branches_matching(origin.path(), "harness/").is_empty(),
        "harness branch should have been deleted by rollback"
    );
}

#[test]
fn resolve_base_ref_prefers_tracking_remote_head_over_local_head() {
    let checkout = init_checkout_with_upstream_remote();
    let remote_tip = git_head_sha(checkout.path(), "upstream/main");

    commit_file(
        checkout.path(),
        "LOCAL",
        b"local-only",
        "local-only diverges from upstream/main",
    );
    let local_tip = git_head_sha(checkout.path(), "HEAD");
    assert_ne!(
        local_tip, remote_tip,
        "test setup must diverge from upstream"
    );

    let repository = crate::git::GitRepository::discover(checkout.path()).expect("discover repo");
    let resolved = resolve_base_ref(&repository).expect("resolve base ref");
    assert_eq!(resolved, "upstream/main");
}
