use super::*;

#[test]
fn symbolic_branch_ref_never_mutates_its_target() {
    let fixture = Fixture::new(false);
    run_git(
        &fixture.controller,
        &["update-ref", "refs/heads/actual", &fixture.base],
    );
    run_git(
        &fixture.controller,
        &["symbolic-ref", "refs/heads/main", "refs/heads/actual"],
    );

    let error = fixture
        .plan()
        .verify_and_import_objects(&fixture.bundle)
        .expect_err("symbolic target branch must fail closed");

    assert!(matches!(error, GitError::Unsafe { .. }));
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "refs/heads/actual"]),
        fixture.base
    );
    assert!(git(&fixture.controller, &["status", "--porcelain"]).is_empty());
}

#[test]
fn symbolic_private_ref_never_deletes_or_rewrites_its_target() {
    let fixture = Fixture::new(false);
    fixture.apply();
    let private_ref = import_ref();
    let target_ref = "refs/harness/task-board/import-target";
    run_git(
        &fixture.controller,
        &["update-ref", "-d", &private_ref, &fixture.result],
    );
    run_git(
        &fixture.controller,
        &["update-ref", target_ref, &fixture.result],
    );
    run_git(
        &fixture.controller,
        &["symbolic-ref", &private_ref, target_ref],
    );

    let replay = fixture
        .plan()
        .require_applied()
        .expect_err("symbolic private ref must fail exact replay");
    assert!(matches!(replay, GitError::Unsafe { .. }));
    let cleanup = fixture
        .plan()
        .cleanup_import_ref()
        .expect_err("symbolic private ref must fail cleanup");
    assert!(matches!(cleanup, GitError::Unsafe { .. }));
    assert_eq!(
        git(&fixture.controller, &["rev-parse", target_ref]),
        fixture.result
    );
    assert_eq!(
        git(&fixture.controller, &["symbolic-ref", &private_ref]),
        target_ref
    );
}
