use std::path::{Path, PathBuf};
use std::process::Command;

use sha2::{Digest as _, Sha256};

use super::GitSourceBundleImportPlan;
use crate::git::source_bundle_export::GitSourceBundleExportPlan;

#[path = "quarantine_tests.rs"]
mod quarantine_tests;

const REPOSITORY: &str = "example/widgets";

#[test]
fn imports_exact_self_contained_snapshot_and_replays_across_cleanup() {
    let fixture = Fixture::new();
    let plan = fixture.import_plan();

    plan.verify_and_import_bytes(&fixture.bytes)
        .expect("import exact source snapshot");
    plan.require_imported().expect("require imported snapshot");
    assert_eq!(
        git(&fixture.target, &["rev-parse", &fixture.import_ref]),
        fixture.revision
    );

    plan.verify_and_import_bytes(&fixture.bytes)
        .expect("replay exact source snapshot");
    plan.cleanup_import_ref()
        .expect("cleanup exact source import ref");
    plan.cleanup_import_ref()
        .expect("replay source import cleanup");
    assert!(!git_ref_exists(&fixture.target, &fixture.import_ref));

    plan.verify_and_import_bytes(&fixture.bytes)
        .expect("restart source snapshot import");
    assert_eq!(
        git(&fixture.target, &["rev-parse", &fixture.revision]),
        fixture.revision
    );
}

#[test]
fn digest_or_repository_mismatch_performs_zero_import_mutation() {
    let fixture = Fixture::new();
    let mut tampered = fixture.bytes.clone();
    tampered[0] ^= 1;
    fixture
        .import_plan()
        .verify_and_import_bytes(&tampered)
        .expect_err("tampered snapshot bytes must fail");
    assert!(!git_ref_exists(&fixture.target, &fixture.import_ref));
    assert!(!git_object_exists(&fixture.target, &fixture.revision));

    for origin in [
        "https://github.com/example/upstream.git",
        "https://evil.invalid/example/widgets.git",
    ] {
        git(&fixture.target, &["remote", "set-url", "origin", origin]);
        fixture
            .import_plan_result()
            .expect_err("snapshot repository mismatch must fail");
        assert!(!git_ref_exists(&fixture.target, &fixture.import_ref));
        assert!(!git_object_exists(&fixture.target, &fixture.revision));
    }
}

#[test]
fn advertised_ref_and_symbolic_import_ref_fail_closed() {
    let fixture = Fixture::new();
    GitSourceBundleImportPlan::new(
        &fixture.target,
        REPOSITORY.into(),
        fixture.revision.clone(),
        format!("refs/harness/task-board/results/{}", fixture.revision),
        &fixture.offer_sha256,
        fixture.bundle_sha256.clone(),
        fixture.bundle_size,
    )
    .expect_err("snapshot advertised ref must be exact");
    GitSourceBundleImportPlan::new(
        &fixture.target,
        REPOSITORY.into(),
        fixture.revision.clone(),
        fixture.advertised_ref.clone(),
        "not-deterministic",
        fixture.bundle_sha256.clone(),
        fixture.bundle_size,
    )
    .expect_err("snapshot import ref must bind exact request and bundle digests");
    assert!(!git_object_exists(&fixture.target, &fixture.revision));

    let target_ref = "refs/harness/task-board/source-target";
    let target_head = git(&fixture.target, &["rev-parse", "HEAD"]);
    git(&fixture.target, &["update-ref", target_ref, &target_head]);
    git(
        &fixture.target,
        &["symbolic-ref", &fixture.import_ref, target_ref],
    );
    fixture
        .import_plan()
        .verify_and_import_bytes(&fixture.bytes)
        .expect_err("symbolic source import ref must fail");
    assert_eq!(
        git(&fixture.target, &["rev-parse", target_ref]),
        target_head
    );
    assert_eq!(
        git(&fixture.target, &["symbolic-ref", &fixture.import_ref]),
        target_ref
    );
}

#[test]
fn in_progress_git_operation_performs_zero_import_mutation() {
    let fixture = Fixture::new();
    fs_err::write(fixture.target.join(".git/MERGE_HEAD"), &fixture.revision)
        .expect("seed in-progress merge marker");

    fixture
        .import_plan()
        .verify_and_import_bytes(&fixture.bytes)
        .expect_err("in-progress Git operation must block source import");

    assert!(!git_ref_exists(&fixture.target, &fixture.import_ref));
    assert!(!git_object_exists(&fixture.target, &fixture.revision));
}

struct Fixture {
    _temp: tempfile::TempDir,
    target: PathBuf,
    revision: String,
    advertised_ref: String,
    import_ref: String,
    offer_sha256: String,
    bytes: Vec<u8>,
    bundle_sha256: String,
    bundle_size: u64,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().expect("create source import fixture");
        let source = temp.path().join("source");
        init_repository(&source, "https://github.com/example/widgets.git");
        fs_err::write(source.join("snapshot.txt"), "snapshot\n").expect("write snapshot");
        git(&source, &["add", "snapshot.txt"]);
        git(&source, &["commit", "-m", "snapshot"]);
        let revision = git(&source, &["rev-parse", "HEAD"]);
        let export =
            GitSourceBundleExportPlan::for_revision(&source, REPOSITORY.into(), revision.clone())
                .expect("source export plan")
                .export(4 * 1024 * 1024)
                .expect("source export");

        let target = temp.path().join("target");
        init_repository(&target, "https://github.com/example/widgets.git");
        let offer_sha256 = "a".repeat(64);
        let bundle_sha256 = hex::encode(Sha256::digest(&export.bytes));
        let import_ref =
            format!("refs/harness/task-board/source-imports/{offer_sha256}/{bundle_sha256}");
        Self {
            _temp: temp,
            target,
            revision,
            advertised_ref: export.advertised_ref,
            import_ref,
            offer_sha256,
            bundle_sha256,
            bundle_size: u64::try_from(export.bytes.len()).expect("bundle size"),
            bytes: export.bytes,
        }
    }

    fn import_plan(&self) -> GitSourceBundleImportPlan {
        self.import_plan_result().expect("source import plan")
    }

    fn import_plan_result(&self) -> crate::git::GitResult<GitSourceBundleImportPlan> {
        GitSourceBundleImportPlan::new(
            &self.target,
            REPOSITORY.into(),
            self.revision.clone(),
            self.advertised_ref.clone(),
            &self.offer_sha256,
            self.bundle_sha256.clone(),
            self.bundle_size,
        )
    }
}

fn init_repository(path: &Path, origin: &str) {
    fs_err::create_dir_all(path).expect("create repository");
    git(path, &["init", "-b", "main"]);
    git(path, &["config", "user.name", "Harness Test"]);
    git(path, &["config", "user.email", "test@example.com"]);
    git(path, &["remote", "add", "origin", origin]);
    fs_err::write(path.join("base.txt"), path.to_string_lossy().as_bytes()).expect("write base");
    git(path, &["add", "base.txt"]);
    git(path, &["commit", "-m", "base"]);
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
    String::from_utf8(output.stdout)
        .expect("git output utf8")
        .trim()
        .to_owned()
}

fn git_ref_exists(repository: &Path, reference: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(["rev-parse", "--verify", "--quiet", reference])
        .output()
        .expect("query Git ref")
        .status
        .success()
}

fn git_object_exists(repository: &Path, revision: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(["cat-file", "-e", &format!("{revision}^{{commit}}")])
        .output()
        .expect("query Git object")
        .status
        .success()
}
