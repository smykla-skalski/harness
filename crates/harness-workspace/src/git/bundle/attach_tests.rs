use super::*;

#[test]
fn exact_attach_transaction_refuses_a_branch_race_without_attaching_head() {
    let fixture = Fixture::new(false);
    let plan = fixture.plan();
    plan.verify_and_import_objects(&fixture.bundle)
        .expect("import objects");
    plan.advance_one().expect("detach exact result");
    assert_eq!(
        plan.advance_one().expect("advance exact branch"),
        GitBundleWorktreeState::DetachedResultBranchResult
    );
    let tree = git(
        &fixture.controller,
        &["rev-parse", &format!("{}^{{tree}}", fixture.result)],
    );
    let interloper = git_with_input(
        &fixture.controller,
        &["commit-tree", &tree, "-p", &fixture.base],
        "attach interloper\n",
    );
    run_git(
        &fixture.controller,
        &[
            "update-ref",
            "refs/heads/main",
            &interloper,
            &fixture.result,
        ],
    );

    plan.attach_result_branch()
        .expect_err("moved branch must fail the exact attach transaction");

    assert!(!git_succeeds(
        &fixture.controller,
        &["symbolic-ref", "--quiet", "HEAD"],
    ));
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "HEAD"]),
        fixture.result
    );
    assert_eq!(
        git(&fixture.controller, &["rev-parse", "refs/heads/main"]),
        interloper
    );
    assert!(git(&fixture.controller, &["status", "--porcelain"]).is_empty());
}
