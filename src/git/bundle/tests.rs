use std::path::{Path, PathBuf};
use std::process::Command;

use fs_err as fs;
use tempfile::TempDir;

use super::{GitBundleImportPlan, GitBundleWorktreeState};
use crate::git::GitError;

#[path = "attach_tests.rs"]
mod attach_tests;
#[path = "contract_tests.rs"]
mod contract_tests;
#[path = "quarantine_tests.rs"]
mod quarantine_tests;
#[path = "staging_tests.rs"]
mod staging_tests;
#[path = "symbolic_ref_tests.rs"]
mod symbolic_ref_tests;

const OFFER_SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const BUNDLE_SHA: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[test]
fn imports_and_replays_each_crash_safe_git_boundary() {
    let fixture = Fixture::new(false);
    let plan = fixture.plan();

    plan.verify_and_import_objects(&fixture.bundle)
        .expect("verify and import objects");
    assert_eq!(
        plan.state().expect("base state"),
        GitBundleWorktreeState::AttachedBase
    );

    assert_eq!(
        plan.advance_one().expect("detach exact result"),
        GitBundleWorktreeState::DetachedResultBranchBase
    );
    let replay = fixture.plan();
    replay
        .verify_and_import_objects(&fixture.bundle)
        .expect("replay imported objects");
    assert_eq!(
        replay.advance_one().expect("advance branch by exact CAS"),
        GitBundleWorktreeState::DetachedResultBranchResult
    );

    let replay = fixture.plan();
    assert_eq!(
        replay.advance_one().expect("reattach exact branch"),
        GitBundleWorktreeState::AttachedResult
    );
    let evidence = fixture.plan().require_applied().expect("applied evidence");
    assert_eq!(evidence.base_revision, fixture.base);
    assert_eq!(evidence.result_revision, fixture.result);
    assert!(git(&fixture.controller, &["status", "--porcelain"]).is_empty());

    fixture
        .plan()
        .cleanup_import_ref()
        .expect("exact import-ref cleanup");
    fixture
        .plan()
        .cleanup_import_ref()
        .expect("replayed import-ref cleanup");
}

#[test]
fn preserves_user_changes_after_a_detached_checkout_crash() {
    let fixture = Fixture::new(false);
    let plan = fixture.plan();
    plan.verify_and_import_objects(&fixture.bundle)
        .expect("import objects");
    assert_eq!(
        plan.advance_one().expect("detach result"),
        GitBundleWorktreeState::DetachedResultBranchBase
    );
    fs::write(fixture.controller.join("result.txt"), "user edit\n").expect("write tracked edit");
    fs::write(fixture.controller.join("untracked.txt"), "keep me\n").expect("write untracked edit");

    fixture
        .plan()
        .advance_one()
        .expect_err("dirty replay must fail closed");

    assert_eq!(
        fs::read_to_string(fixture.controller.join("result.txt")).expect("tracked edit"),
        "user edit\n"
    );
    assert_eq!(
        fs::read_to_string(fixture.controller.join("untracked.txt")).expect("untracked edit"),
        "keep me\n"
    );
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "refs/heads/main"]),
        fixture.base
    );
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "HEAD"]),
        fixture.result
    );
}

#[test]
fn exact_old_head_cas_refuses_an_interleaving_branch_advance() {
    let fixture = Fixture::new(false);
    let plan = fixture.plan();
    plan.verify_and_import_objects(&fixture.bundle)
        .expect("import objects");
    plan.advance_one().expect("detach exact result");
    let tree = git(
        &fixture.controller,
        &["rev-parse", &format!("{}^{{tree}}", fixture.base)],
    );
    let interloper = git_with_input(
        &fixture.controller,
        &["commit-tree", &tree, "-p", &fixture.base],
        "interloper\n",
    );
    run_git(
        &fixture.controller,
        &["update-ref", "refs/heads/main", &interloper, &fixture.base],
    );

    fixture
        .plan()
        .advance_one()
        .expect_err("moved branch must fail exact replay");

    assert_eq!(
        git(&fixture.controller, &["rev-parse", "refs/heads/main"]),
        interloper
    );
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "HEAD"]),
        fixture.result
    );
    assert!(git(&fixture.controller, &["status", "--porcelain"]).is_empty());
}

#[test]
fn rejects_extra_heads_and_non_descendant_results_without_worktree_mutation() {
    let extra = Fixture::new(true);
    extra
        .plan()
        .verify_and_import_objects(&extra.bundle)
        .expect_err("extra advertised head must fail");
    extra.assert_untouched();

    let unrelated = Fixture::new_unrelated();
    unrelated
        .plan()
        .verify_and_import_objects(&unrelated.bundle)
        .expect_err("unrelated result must fail ancestry");
    unrelated.assert_untouched();
}

#[test]
fn in_progress_operation_in_the_target_worktree_blocks_result_import() {
    let fixture = Fixture::new(false);
    fs::write(fixture.controller.join(".git/MERGE_HEAD"), &fixture.result)
        .expect("seed in-progress merge marker");

    fixture
        .plan()
        .verify_and_import_objects(&fixture.bundle)
        .expect_err("target Git operation must block result import");

    fixture.assert_untouched();
}

#[test]
fn rejects_noncanonical_private_import_ref_before_bundle_mutation() {
    let fixture = Fixture::new(false);

    GitBundleImportPlan::new(
        &fixture.controller,
        "refs/heads/main".into(),
        fixture.base.clone(),
        fixture.result.clone(),
        result_ref(),
        "refs/harness/task-board/imports/not-deterministic".into(),
    )
    .expect_err("private result import ref must contain exact digest segments");

    fixture.assert_untouched();
}

#[test]
fn applied_replay_rejects_dirty_worktree_without_overwriting_bytes() {
    let fixture = Fixture::new(false);
    fixture.apply();
    fs::write(
        fixture.controller.join("result.txt"),
        "local edit after import\n",
    )
    .expect("write local edit");
    fs::write(
        fixture.controller.join("untracked.txt"),
        "preserve untracked\n",
    )
    .expect("write untracked file");

    let error = fixture
        .plan()
        .require_applied()
        .expect_err("dirty applied replay must fail closed");

    assert!(matches!(error, GitError::Unsafe { .. }));
    assert_eq!(
        fs::read_to_string(fixture.controller.join("result.txt")).expect("read local edit"),
        "local edit after import\n"
    );
    assert_eq!(
        fs::read_to_string(fixture.controller.join("untracked.txt")).expect("read untracked"),
        "preserve untracked\n"
    );
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "HEAD"]),
        fixture.result
    );
}

#[test]
fn applied_replay_rejects_branch_and_head_drift_without_ref_repair() {
    let branch_drift = Fixture::new(false);
    branch_drift.apply();
    let tree = git(
        &branch_drift.controller,
        &["rev-parse", &format!("{}^{{tree}}", branch_drift.result)],
    );
    let interloper = git_with_input(
        &branch_drift.controller,
        &["commit-tree", &tree, "-p", &branch_drift.base],
        "same-tree interloper\n",
    );
    run_git(
        &branch_drift.controller,
        &[
            "update-ref",
            "refs/heads/main",
            &interloper,
            &branch_drift.result,
        ],
    );
    let error = branch_drift
        .plan()
        .require_applied()
        .expect_err("same-tree branch drift must fail closed");
    assert!(matches!(error, GitError::Unsafe { .. }));
    assert_eq!(
        git(&branch_drift.controller, &["rev-parse", "refs/heads/main"]),
        interloper
    );

    let head_drift = Fixture::new(false);
    head_drift.apply();
    run_git(
        &head_drift.controller,
        &["checkout", "--detach", &head_drift.result],
    );
    let error = head_drift
        .plan()
        .require_applied()
        .expect_err("detached applied head must fail closed");
    assert!(matches!(error, GitError::Unsafe { .. }));
    assert_eq!(
        git(&head_drift.controller, &["rev-parse", "HEAD"]),
        head_drift.result
    );
    assert_eq!(
        git(&head_drift.controller, &["rev-parse", "refs/heads/main"]),
        head_drift.result
    );
}

#[test]
fn applied_replay_rejects_private_ref_drift_without_repair() {
    let fixture = Fixture::new(false);
    fixture.apply();
    run_git(
        &fixture.controller,
        &["update-ref", &import_ref(), &fixture.base, &fixture.result],
    );

    let error = fixture
        .plan()
        .require_applied()
        .expect_err("changed private import ref must fail closed");

    assert!(matches!(error, GitError::Unsafe { .. }));
    assert_eq!(
        git(&fixture.controller, &["rev-parse", &import_ref()]),
        fixture.base
    );
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "HEAD"]),
        fixture.result
    );
}

struct Fixture {
    _temp: TempDir,
    source: PathBuf,
    controller: PathBuf,
    bundle: PathBuf,
    base: String,
    result: String,
}

impl Fixture {
    fn new(extra_head: bool) -> Self {
        let temp = tempfile::tempdir().expect("tempdir");
        let source = temp.path().join("source");
        let controller = temp.path().join("controller");
        fs::create_dir_all(&source).expect("source directory");
        run_git(&source, &["init", "-b", "main"]);
        configure(&source);
        fs::write(source.join("README.md"), "base\n").expect("base file");
        run_git(&source, &["add", "README.md"]);
        run_git(&source, &["commit", "-m", "base"]);
        let base = git(&source, &["rev-parse", "HEAD"]);
        run_git(temp.path(), &["clone", path(&source), path(&controller)]);
        configure(&controller);

        fs::write(source.join("result.txt"), "result\n").expect("result file");
        run_git(&source, &["add", "result.txt"]);
        run_git(&source, &["commit", "-m", "result"]);
        let result = git(&source, &["rev-parse", "HEAD"]);
        let result_ref = result_ref();
        run_git(&source, &["update-ref", &result_ref, &result]);
        let bundle = temp.path().join("implementation.bundle");
        let mut args = vec![
            "bundle",
            "create",
            "--version=2",
            path(&bundle),
            &result_ref,
        ];
        let extra_ref = format!("refs/harness/task-board/results/{BUNDLE_SHA}");
        if extra_head {
            // `^base` below excludes a base-targeted ref, so target the included result instead.
            run_git(&source, &["update-ref", &extra_ref, &result]);
            args.push(&extra_ref);
        }
        let excluded = format!("^{base}");
        args.push(&excluded);
        run_git(&source, &args);
        Self {
            _temp: temp,
            source,
            controller,
            bundle,
            base,
            result,
        }
    }

    fn new_unrelated() -> Self {
        let mut fixture = Self::new(false);
        run_git(&fixture.source, &["checkout", "--orphan", "unrelated"]);
        run_git(&fixture.source, &["rm", "-rf", "."]);
        fs::write(fixture.source.join("other.txt"), "other\n").expect("orphan file");
        run_git(&fixture.source, &["add", "other.txt"]);
        run_git(&fixture.source, &["commit", "-m", "unrelated"]);
        fixture.result = git(&fixture.source, &["rev-parse", "HEAD"]);
        let result_ref = result_ref();
        run_git(
            &fixture.source,
            &["update-ref", &result_ref, &fixture.result],
        );
        let excluded = format!("^{}", fixture.base);
        run_git(
            &fixture.source,
            &[
                "bundle",
                "create",
                "--version=2",
                path(&fixture.bundle),
                &result_ref,
                &excluded,
            ],
        );
        fixture
    }

    fn plan(&self) -> GitBundleImportPlan {
        GitBundleImportPlan::new(
            &self.controller,
            "refs/heads/main".into(),
            self.base.clone(),
            self.result.clone(),
            result_ref(),
            import_ref(),
        )
        .expect("bundle import plan")
    }

    fn apply(&self) {
        let plan = self.plan();
        plan.verify_and_import_objects(&self.bundle)
            .expect("import bundle objects");
        while plan.state().expect("read import state") != GitBundleWorktreeState::AttachedResult {
            plan.advance_one().expect("advance import state");
        }
        plan.require_applied().expect("prove applied import");
    }

    fn assert_untouched(&self) {
        assert_eq!(git(&self.controller, &["rev-parse", "HEAD"]), self.base);
        assert_eq!(
            git(&self.controller, &["rev-parse", "refs/heads/main"]),
            self.base
        );
        assert!(git(&self.controller, &["status", "--porcelain"]).is_empty());
        let import = Command::new("git")
            .arg("-C")
            .arg(&self.controller)
            .args(["rev-parse", "--verify", "--quiet", &import_ref()])
            .status()
            .expect("inspect import ref");
        assert!(!import.success());
    }
}

fn result_ref() -> String {
    format!("refs/harness/task-board/results/{OFFER_SHA}")
}

fn import_ref() -> String {
    format!("refs/harness/task-board/imports/{OFFER_SHA}/{BUNDLE_SHA}")
}

fn configure(repository: &Path) {
    run_git(repository, &["config", "user.name", "Harness Test"]);
    run_git(repository, &["config", "user.email", "test@example.com"]);
    run_git(repository, &["config", "commit.gpgsign", "false"]);
}

fn run_git(repository: &Path, args: &[&str]) {
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

fn git(repository: &Path, args: &[&str]) -> String {
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
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn git_succeeds(repository: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .output()
        .expect("run git status command")
        .status
        .success()
}

fn git_with_input(repository: &Path, args: &[&str], input: &str) -> String {
    use std::io::Write as _;
    use std::process::Stdio;

    let mut child = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("run git with input");
    child
        .stdin
        .take()
        .expect("git stdin")
        .write_all(input.as_bytes())
        .expect("write git input");
    let output = child.wait_with_output().expect("wait for git");
    assert!(output.status.success());
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn path(path: &Path) -> &str {
    path.to_str().expect("utf8 test path")
}
