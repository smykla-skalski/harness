use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

use super::GitBundleExportPlan;

#[test]
fn exports_one_exact_bounded_descendant_and_cleans_the_private_ref() {
    let fixture = Fixture::new();
    let plan = fixture.plan();
    let bundle = plan.export(4 * 1024 * 1024).expect("export exact bundle");

    assert_eq!(bundle.base_revision, fixture.base);
    assert_eq!(bundle.result_revision, fixture.result);
    assert_eq!(bundle.advertised_ref, fixture.result_ref());
    assert!(bundle.bytes.starts_with(b"# v2 git bundle\n"));
    assert!(bundle.bytes.len() < 4 * 1024 * 1024);
    assert!(
        optional_git(
            &fixture.worktree,
            &["rev-parse", "--verify", "--quiet", &fixture.result_ref()]
        )
        .is_none()
    );
}

#[test]
fn rejects_dirty_wrong_head_non_descendant_and_too_small_limit() {
    let fixture = Fixture::new();
    fs_err::write(fixture.worktree.join("dirty.txt"), "dirty\n").expect("write dirty file");
    assert!(fixture.plan_result().is_err());
    fs_err::remove_file(fixture.worktree.join("dirty.txt")).expect("remove dirty file");

    git(&fixture.worktree, &["checkout", "--detach", &fixture.base]);
    assert!(fixture.plan_result().is_err());
    git(&fixture.worktree, &["checkout", "main"]);

    let unrelated = git(
        &fixture.worktree,
        &["commit-tree", "HEAD^{tree}", "-m", "unrelated"],
    );
    assert!(
        GitBundleExportPlan::for_result(&fixture.worktree, fixture.result.clone(), unrelated,)
            .is_err()
    );
    assert!(fixture.plan().export(1).is_err());
    assert!(
        optional_git(
            &fixture.worktree,
            &["rev-parse", "--verify", "--quiet", &fixture.result_ref()]
        )
        .is_none()
    );
}

#[test]
fn replayed_private_ref_must_match_and_is_removed_exactly() {
    let fixture = Fixture::new();
    let result_ref = fixture.result_ref();
    git(
        &fixture.worktree,
        &["update-ref", &result_ref, &fixture.result],
    );
    fixture
        .plan()
        .export(4 * 1024 * 1024)
        .expect("resume exact export ref");
    assert!(
        optional_git(
            &fixture.worktree,
            &["rev-parse", "--verify", "--quiet", &result_ref]
        )
        .is_none()
    );

    git(
        &fixture.worktree,
        &["update-ref", &result_ref, &fixture.base],
    );
    assert!(fixture.plan().export(4 * 1024 * 1024).is_err());
    assert_eq!(
        git(&fixture.worktree, &["rev-parse", &result_ref]),
        fixture.base
    );
}

#[test]
fn symbolic_result_ref_never_mutates_its_direct_target() {
    let fixture = Fixture::new();
    let result_ref = fixture.result_ref();
    let target_ref = "refs/harness/task-board/export-target";
    git(
        &fixture.worktree,
        &["update-ref", target_ref, &fixture.result],
    );
    git(
        &fixture.worktree,
        &["symbolic-ref", &result_ref, target_ref],
    );

    fixture
        .plan()
        .export(4 * 1024 * 1024)
        .expect_err("symbolic export ref must fail closed");

    assert_eq!(
        git(&fixture.worktree, &["rev-parse", target_ref]),
        fixture.result
    );
    assert_eq!(
        git(&fixture.worktree, &["symbolic-ref", &result_ref]),
        target_ref
    );
}

#[test]
fn symbolic_result_ref_never_deletes_its_direct_target_during_cleanup() {
    let fixture = Fixture::new();
    let plan = fixture.plan();
    let result_ref = fixture.result_ref();
    let target_ref = "refs/harness/task-board/export-cleanup-target";
    plan.create_or_verify_result_ref()
        .expect("create exact direct result ref");
    git(
        &fixture.worktree,
        &["update-ref", "-d", &result_ref, &fixture.result],
    );
    git(
        &fixture.worktree,
        &["update-ref", target_ref, &fixture.result],
    );
    git(
        &fixture.worktree,
        &["symbolic-ref", &result_ref, target_ref],
    );

    plan.cleanup_result_ref()
        .expect_err("symbolic cleanup ref must fail closed");

    assert_eq!(
        git(&fixture.worktree, &["rev-parse", target_ref]),
        fixture.result
    );
    assert_eq!(
        git(&fixture.worktree, &["symbolic-ref", &result_ref]),
        target_ref
    );
}

struct Fixture {
    _temp: TempDir,
    worktree: PathBuf,
    base: String,
    result: String,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().expect("create tempdir");
        let worktree = temp.path().join("worktree");
        fs_err::create_dir_all(&worktree).expect("create worktree");
        git(&worktree, &["init", "-b", "main"]);
        git(&worktree, &["config", "user.name", "Harness Test"]);
        git(&worktree, &["config", "user.email", "test@example.com"]);
        fs_err::write(worktree.join("result.txt"), "base\n").expect("write base");
        git(&worktree, &["add", "result.txt"]);
        git(&worktree, &["commit", "-m", "base"]);
        let base = git(&worktree, &["rev-parse", "HEAD"]);
        fs_err::write(worktree.join("result.txt"), "result\n").expect("write result");
        git(&worktree, &["commit", "-am", "result"]);
        let result = git(&worktree, &["rev-parse", "HEAD"]);
        Self {
            _temp: temp,
            worktree,
            base,
            result,
        }
    }

    fn plan(&self) -> GitBundleExportPlan {
        self.plan_result().expect("bundle export plan")
    }

    fn plan_result(&self) -> crate::git::GitResult<GitBundleExportPlan> {
        GitBundleExportPlan::for_result(&self.worktree, self.base.clone(), self.result.clone())
    }

    fn result_ref(&self) -> String {
        format!("refs/harness/task-board/results/{}", self.result)
    }
}

fn git(repository: &Path, args: &[&str]) -> String {
    optional_git(repository, args).unwrap_or_else(|| panic!("git {args:?} failed"))
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
