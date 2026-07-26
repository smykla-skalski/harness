use super::*;
use crate::git::GitError;
use crate::git::bundle_contract::GitBundleContentLimits;
use crate::git::quarantine_test_support::bundle_with_extra_blob;

const EXTRA_BLOB_BYTES: usize = 1024 * 1024;

#[test]
fn extra_unreachable_object_is_bounded_before_source_pack_promotion() {
    let accepted = Fixture::new();
    let (accepted_bytes, accepted_extra) = extra_object_bundle(&accepted);
    let (accepted_plan, accepted_ref) = plan_for_bytes(&accepted, &accepted_bytes);

    accepted_plan
        .verify_and_import_bytes_with_limits(&accepted_bytes, extra_object_limits(EXTRA_BLOB_BYTES))
        .expect("exact inflated-object boundary");
    assert!(object_exists(&accepted.target, &accepted_extra));
    assert!(git_ref_exists(&accepted.target, &accepted_ref));

    let rejected = Fixture::new();
    let (rejected_bytes, rejected_extra) = extra_object_bundle(&rejected);
    let (rejected_plan, rejected_ref) = plan_for_bytes(&rejected, &rejected_bytes);
    let head = git(&rejected.target, &["rev-parse", "HEAD"]);
    let error = rejected_plan
        .verify_and_import_bytes_with_limits(
            &rejected_bytes,
            extra_object_limits(EXTRA_BLOB_BYTES - 1),
        )
        .expect_err("one excess unreachable object byte must fail closed");

    assert!(matches!(error, GitError::Unsafe { .. }));
    assert_rejected_import_left_no_trace(&rejected, &head, &rejected_ref, &rejected_extra);
}

fn assert_rejected_import_left_no_trace(
    fixture: &Fixture,
    head: &str,
    import_ref: &str,
    extra_object: &str,
) {
    assert_eq!(git(&fixture.target, &["rev-parse", "HEAD"]), head);
    assert!(git(&fixture.target, &["status", "--porcelain"]).is_empty());
    assert!(!git_ref_exists(&fixture.target, import_ref));
    assert!(!object_exists(&fixture.target, &fixture.revision));
    assert!(!object_exists(&fixture.target, extra_object));
    assert!(!quarantine_path(&fixture.target).exists());
}

fn extra_object_bundle(fixture: &Fixture) -> (Vec<u8>, String) {
    let blob = vec![b'x'; EXTRA_BLOB_BYTES];
    bundle_with_extra_blob(
        &fixture.temp.path().join("source"),
        &fixture.bytes,
        &[fixture.revision.as_str()],
        &blob,
    )
}

fn plan_for_bytes(fixture: &Fixture, bytes: &[u8]) -> (GitSourceBundleImportPlan, String) {
    let digest = hex::encode(Sha256::digest(bytes));
    let import_ref = format!(
        "refs/harness/task-board/source-imports/{}/{}",
        fixture.offer_sha256, digest
    );
    let plan = GitSourceBundleImportPlan::new(
        &fixture.target,
        REPOSITORY.into(),
        fixture.revision.clone(),
        fixture.advertised_ref.clone(),
        &fixture.offer_sha256,
        digest,
        u64::try_from(bytes.len()).expect("bundle size"),
    )
    .expect("source import plan");
    (plan, import_ref)
}

fn extra_object_limits(max_object_bytes: usize) -> GitBundleContentLimits {
    GitBundleContentLimits {
        inflated_object_bytes: u64::try_from(max_object_bytes).expect("object size"),
        ..GitBundleContentLimits::REMOTE_RESULT
    }
}

fn object_exists(repository: &Path, object: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(["cat-file", "-e", object])
        .output()
        .expect("query Git object")
        .status
        .success()
}

fn quarantine_path(repository: &Path) -> PathBuf {
    repository
        .join(".git/objects")
        .join("harness-task-board-quarantine")
}
