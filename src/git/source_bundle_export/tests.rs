use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

use super::GitSourceBundleExportPlan;

const REPOSITORY: &str = "example/widgets";

#[test]
fn exports_one_self_contained_exact_revision_and_cleans_private_ref() {
    let fixture = Fixture::new();
    let bundle = fixture
        .plan()
        .export(4 * 1024 * 1024)
        .expect("export exact source bundle");

    assert_eq!(bundle.repository, REPOSITORY);
    assert_eq!(bundle.revision, fixture.revision);
    assert_eq!(bundle.advertised_ref, fixture.source_ref());
    assert!(bundle.bytes.starts_with(b"# v2 git bundle\n"));
    assert!(!bundle.bytes.windows(2).any(|window| window == b"\n-"));
    assert!(
        optional_git(
            &fixture.worktree,
            &["rev-parse", "--verify", "--quiet", &fixture.source_ref()],
        )
        .is_none()
    );

    let bundle_path = fixture._temp.path().join("source.bundle");
    fs_err::write(&bundle_path, &bundle.bytes).expect("write source bundle");
    let clone = fixture._temp.path().join("clone");
    fs_err::create_dir_all(&clone).expect("create clone");
    git(&clone, &["init", "--bare"]);
    git_at(
        &clone,
        &[
            "fetch",
            bundle_path.to_str().expect("bundle path"),
            &format!("{}:refs/heads/source", bundle.advertised_ref),
        ],
    );
    assert_eq!(
        git(&clone, &["rev-parse", "refs/heads/source"]),
        fixture.revision
    );
}

#[test]
fn rejects_noncanonical_repository_dirty_wrong_head_and_small_limit() {
    let fixture = Fixture::new();
    assert!(
        GitSourceBundleExportPlan::for_revision(
            &fixture.worktree,
            "Example/Widgets".into(),
            fixture.revision.clone(),
        )
        .is_err()
    );
    fs_err::write(fixture.worktree.join("dirty.txt"), "dirty\n").expect("write dirty file");
    assert!(fixture.plan_result().is_err());
    fs_err::remove_file(fixture.worktree.join("dirty.txt")).expect("remove dirty file");

    git(&fixture.worktree, &["checkout", "HEAD^"]);
    assert!(fixture.plan_result().is_err());
    git(&fixture.worktree, &["checkout", "main"]);
    assert!(fixture.plan().export(1).is_err());
}

#[test]
fn fork_or_hostile_origin_rejects_without_exporting_a_private_ref() {
    let fixture = Fixture::new();
    for origin in [
        "https://github.com/example/upstream.git",
        "https://evil.invalid/example/widgets.git",
        "ssh://git@evil.invalid/example/widgets.git",
    ] {
        git(&fixture.worktree, &["remote", "set-url", "origin", origin]);
        fixture
            .plan_result()
            .expect_err("a fork or hostile origin must not export as the frozen repository");
        assert!(
            optional_git(
                &fixture.worktree,
                &["rev-parse", "--verify", "--quiet", &fixture.source_ref()],
            )
            .is_none(),
            "repository mismatch must perform zero export mutation"
        );
    }
    let oversized = format!(
        "https://github.com/{}/widgets.git",
        "attacker".repeat(1024)
    );
    git(
        &fixture.worktree,
        &["remote", "set-url", "origin", &oversized],
    );
    fixture
        .plan_result()
        .expect_err("oversized repository origin must fail its bounded proof");
    assert!(
        optional_git(
            &fixture.worktree,
            &["rev-parse", "--verify", "--quiet", &fixture.source_ref()],
        )
        .is_none()
    );
}

#[test]
fn configured_checkout_common_dir_proves_a_linked_worktree_without_origin() {
    let fixture = Fixture::new();
    git(&fixture.worktree, &["remote", "remove", "origin"]);
    let linked = fixture._temp.path().join("linked");
    git(
        &fixture.worktree,
        &[
            "worktree",
            "add",
            "--detach",
            linked.to_str().expect("linked worktree path"),
            &fixture.revision,
        ],
    );

    let bundle = GitSourceBundleExportPlan::for_configured_revision(
        &linked,
        &fixture.worktree,
        REPOSITORY.into(),
        fixture.revision.clone(),
    )
    .expect("configured checkout identity")
    .export(4 * 1024 * 1024)
    .expect("export from exact configured repository");

    assert_eq!(bundle.repository, REPOSITORY);
    assert_eq!(bundle.revision, fixture.revision);
}

#[test]
fn in_progress_operation_performs_zero_source_export_mutation() {
    let fixture = Fixture::new();
    fs_err::write(fixture.worktree.join(".git/MERGE_HEAD"), &fixture.revision)
        .expect("seed source merge marker");

    fixture
        .plan_result()
        .expect_err("in-progress source operation must block export");

    assert!(
        optional_git(
            &fixture.worktree,
            &["rev-parse", "--verify", "--quiet", &fixture.source_ref()],
        )
        .is_none()
    );
}

#[test]
fn rejects_checkout_filter_without_invoking_it() {
    let fixture = Fixture::new();
    let marker = fixture._temp.path().join("filter-ran");
    fs_err::write(fixture.worktree.join(".gitattributes"), "result.txt filter=unsafe\n")
        .expect("write attributes");
    git(&fixture.worktree, &["add", ".gitattributes"]);
    git(&fixture.worktree, &["commit", "-m", "attributes"]);
    let revision = git(&fixture.worktree, &["rev-parse", "HEAD"]);
    git(
        &fixture.worktree,
        &[
            "config",
            "filter.unsafe.smudge",
            &format!("touch {}", marker.display()),
        ],
    );

    GitSourceBundleExportPlan::for_revision(
        &fixture.worktree,
        REPOSITORY.into(),
        revision,
    )
    .expect_err("external checkout filter must fail closed");
    assert!(!marker.exists(), "filter process must never run");
}

#[test]
fn symbolic_source_ref_never_mutates_or_deletes_its_target() {
    let fixture = Fixture::new();
    let source_ref = fixture.source_ref();
    let target_ref = "refs/harness/task-board/source-target";
    git(&fixture.worktree, &["update-ref", target_ref, &fixture.revision]);
    git(&fixture.worktree, &["symbolic-ref", &source_ref, target_ref]);

    fixture
        .plan()
        .export(4 * 1024 * 1024)
        .expect_err("symbolic source ref must fail closed");

    assert_eq!(git(&fixture.worktree, &["rev-parse", target_ref]), fixture.revision);
    assert_eq!(git(&fixture.worktree, &["symbolic-ref", &source_ref]), target_ref);
}

#[cfg(unix)]
#[test]
fn rejects_a_source_tree_symlink_with_an_absolute_target() {
    let mut fixture = Fixture::new();
    commit_source_symlink(&mut fixture, "/tmp/outside");

    let error = fixture
        .plan_result()
        .expect_err("an absolute source-tree symlink must fail closed");

    assert!(matches!(error, crate::git::GitError::Unsafe { .. }));
}

#[cfg(unix)]
#[test]
fn rejects_a_source_tree_symlink_that_escapes_the_worktree() {
    let mut fixture = Fixture::new();
    commit_source_symlink(&mut fixture, "../../outside");

    let error = fixture
        .plan_result()
        .expect_err("a worktree-escaping source-tree symlink must fail closed");

    assert!(matches!(error, crate::git::GitError::Unsafe { .. }));
}

#[cfg(unix)]
#[test]
fn accepts_a_source_tree_symlink_contained_in_the_worktree() {
    let mut fixture = Fixture::new();
    commit_source_symlink(&mut fixture, "../result.txt");

    fixture
        .plan()
        .export(4 * 1024 * 1024)
        .expect("a contained source-tree symlink exports");
}

#[cfg(unix)]
fn commit_source_symlink(fixture: &mut Fixture, target: &str) {
    fs_err::create_dir_all(fixture.worktree.join("changed")).expect("symlink parent");
    std::os::unix::fs::symlink(target, fixture.worktree.join("changed/path"))
        .expect("source symlink");
    git(&fixture.worktree, &["add", "changed/path"]);
    git(&fixture.worktree, &["commit", "-m", "source symlink"]);
    fixture.revision = git(&fixture.worktree, &["rev-parse", "HEAD"]);
}

struct Fixture {
    _temp: TempDir,
    worktree: PathBuf,
    revision: String,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().expect("create tempdir");
        let worktree = temp.path().join("worktree");
        fs_err::create_dir_all(&worktree).expect("create worktree");
        git(&worktree, &["init", "-b", "main"]);
        git(&worktree, &["config", "user.name", "Harness Test"]);
        git(&worktree, &["config", "user.email", "test@example.com"]);
        git(
            &worktree,
            &[
                "remote",
                "add",
                "origin",
                "https://github.com/example/widgets.git",
            ],
        );
        fs_err::write(worktree.join("base.txt"), "base\n").expect("write base");
        git(&worktree, &["add", "base.txt"]);
        git(&worktree, &["commit", "-m", "base"]);
        fs_err::write(worktree.join("result.txt"), "result\n").expect("write result");
        git(&worktree, &["add", "result.txt"]);
        git(&worktree, &["commit", "-m", "result"]);
        let revision = git(&worktree, &["rev-parse", "HEAD"]);
        Self {
            _temp: temp,
            worktree,
            revision,
        }
    }

    fn plan(&self) -> GitSourceBundleExportPlan {
        self.plan_result().expect("source bundle export plan")
    }

    fn plan_result(&self) -> crate::git::GitResult<GitSourceBundleExportPlan> {
        GitSourceBundleExportPlan::for_revision(
            &self.worktree,
            REPOSITORY.into(),
            self.revision.clone(),
        )
    }

    fn source_ref(&self) -> String {
        format!("refs/harness/task-board/sources/{}", self.revision)
    }
}

fn git(repository: &Path, args: &[&str]) -> String {
    optional_git(repository, args).unwrap_or_else(|| panic!("git {args:?} failed"))
}

fn git_at(repository: &Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn optional_git(repository: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git");
    output.status.success().then(|| {
        String::from_utf8(output.stdout)
            .expect("git output utf8")
            .trim()
            .to_string()
    })
}
