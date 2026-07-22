use super::*;
use crate::git::bundle_contract::GitBundleContentLimits;
use crate::git::quarantine_test_support::bundle_with_extra_blob;

const EXTRA_BLOB_BYTES: usize = 1024 * 1024;

#[test]
fn extra_unreachable_object_is_bounded_before_result_pack_promotion() {
    let accepted = Fixture::new(false);
    let (accepted_bytes, accepted_extra) = extra_object_bundle(&accepted);
    let limits = extra_object_limits(EXTRA_BLOB_BYTES);

    accepted
        .plan()
        .verify_and_import_bytes_with_limits(&accepted.bundle, &accepted_bytes, limits)
        .expect("exact inflated-object boundary");
    assert!(object_exists(&accepted.controller, &accepted_extra));

    let rejected = Fixture::new(false);
    let (rejected_bytes, rejected_extra) = extra_object_bundle(&rejected);
    let short = extra_object_limits(EXTRA_BLOB_BYTES - 1);
    let error = rejected
        .plan()
        .verify_and_import_bytes_with_limits(&rejected.bundle, &rejected_bytes, short)
        .expect_err("one excess unreachable object byte must fail closed");

    assert!(matches!(error, GitError::Unsafe { .. }));
    rejected.assert_untouched();
    assert!(!object_exists(&rejected.controller, &rejected.result));
    assert!(!object_exists(&rejected.controller, &rejected_extra));
    assert!(!quarantine_path(&rejected.controller).exists());
}

#[cfg(unix)]
#[test]
fn changed_result_symlink_rejects_an_absolute_target() {
    assert_changed_result_symlink_rejected("/tmp/outside");
}

#[cfg(unix)]
#[test]
fn changed_result_symlink_rejects_a_parent_escape_target() {
    assert_changed_result_symlink_rejected("../../outside");
}

#[cfg(unix)]
#[test]
fn changed_result_symlink_accepts_a_contained_relative_target() {
    let fixture = fixture_with_symlink("../result.txt");

    fixture.apply();

    assert_eq!(
        std::fs::read_link(fixture.controller.join("changed/path")).expect("read applied symlink"),
        PathBuf::from("../result.txt")
    );
}

fn extra_object_bundle(fixture: &Fixture) -> (Vec<u8>, String) {
    let valid = fs::read(&fixture.bundle).expect("read valid result bundle");
    let excluded = format!("^{}", fixture.base);
    let blob = vec![b'x'; EXTRA_BLOB_BYTES];
    bundle_with_extra_blob(
        &fixture.source,
        &valid,
        &[fixture.result.as_str(), excluded.as_str()],
        &blob,
    )
}

fn extra_object_limits(max_object_bytes: usize) -> GitBundleContentLimits {
    GitBundleContentLimits {
        max_inflated_object_bytes: u64::try_from(max_object_bytes).expect("object size"),
        ..GitBundleContentLimits::REMOTE_RESULT
    }
}

#[cfg(unix)]
fn assert_changed_result_symlink_rejected(target: &str) {
    let fixture = fixture_with_symlink(target);
    let error = fixture
        .plan()
        .verify_and_import_objects(&fixture.bundle)
        .expect_err("unsafe result symlink must fail before pack promotion");

    assert!(matches!(error, GitError::Unsafe { .. }));
    fixture.assert_untouched();
    assert!(!object_exists(&fixture.controller, &fixture.result));
    assert!(!quarantine_path(&fixture.controller).exists());
}

#[cfg(unix)]
fn fixture_with_symlink(target: &str) -> Fixture {
    use std::os::unix::fs::symlink;

    let mut fixture = Fixture::new(false);
    fs::create_dir_all(fixture.source.join("changed")).expect("symlink parent");
    symlink(target, fixture.source.join("changed/path")).expect("result symlink");
    run_git(&fixture.source, &["add", "changed/path"]);
    run_git(&fixture.source, &["commit", "-m", "result symlink"]);
    fixture.result = git(&fixture.source, &["rev-parse", "HEAD"]);
    run_git(
        &fixture.source,
        &["update-ref", &result_ref(), &fixture.result],
    );
    fs::remove_file(&fixture.bundle).expect("replace result bundle");
    let excluded = format!("^{}", fixture.base);
    run_git(
        &fixture.source,
        &[
            "bundle",
            "create",
            "--version=2",
            path(&fixture.bundle),
            &result_ref(),
            &excluded,
        ],
    );
    fixture
}

fn object_exists(repository: &Path, object: &str) -> bool {
    git_succeeds(repository, &["cat-file", "-e", object])
}

fn quarantine_path(repository: &Path) -> PathBuf {
    repository
        .join(".git/objects")
        .join("harness-task-board-quarantine")
}
