use super::*;
use crate::git::bundle_contract::GitBundleContentLimits;

#[test]
fn rejects_excess_changed_paths_before_ref_or_worktree_mutation() {
    let mut fixture = Fixture::new(false);
    fixture.extend_result("second.txt", "second\n");
    let limits = GitBundleContentLimits {
        changed_paths: 1,
        ..GitBundleContentLimits::REMOTE_RESULT
    };

    fixture
        .plan()
        .verify_and_import_objects_with_limits(&fixture.bundle, limits)
        .expect_err("two changed paths must exceed the exact test limit");

    fixture.assert_untouched();
}

#[test]
fn rejects_excess_materialized_bytes_before_ref_or_worktree_mutation() {
    let fixture = Fixture::new(false);
    let limits = GitBundleContentLimits {
        changed_blob_bytes: 1,
        ..GitBundleContentLimits::REMOTE_RESULT
    };

    fixture
        .plan()
        .verify_and_import_objects_with_limits(&fixture.bundle, limits)
        .expect_err("result blob must exceed the exact test limit");

    fixture.assert_untouched();
}

#[test]
fn rejects_checkout_filters_before_they_can_run() {
    let mut fixture = Fixture::new(false);
    fixture.extend_result(".gitattributes", "result.txt filter=harness-test\n");
    let marker = fixture.controller.join("filter-ran");
    let command = format!("sh -c 'touch {}; cat'", path(&marker));
    run_git(
        &fixture.controller,
        &["config", "filter.harness-test.smudge", &command],
    );

    fixture
        .plan()
        .verify_and_import_objects(&fixture.bundle)
        .expect_err("external checkout filter must be rejected");

    fixture.assert_untouched();
    assert!(!marker.exists(), "checkout filter ran before rejection");
}

#[test]
fn rejects_worktree_encoding_before_ref_or_worktree_mutation() {
    let mut fixture = Fixture::new(false);
    fixture.extend_result(
        ".gitattributes",
        "result.txt working-tree-encoding=UTF-16\n",
    );

    fixture
        .plan()
        .verify_and_import_objects(&fixture.bundle)
        .expect_err("working-tree encoding must be rejected");

    fixture.assert_untouched();
}

impl Fixture {
    fn extend_result(&mut self, changed_path: &str, contents: &str) {
        fs::write(self.source.join(changed_path), contents).expect("write extended result");
        run_git(&self.source, &["add", changed_path]);
        run_git(&self.source, &["commit", "-m", "extend result"]);
        self.result = git(&self.source, &["rev-parse", "HEAD"]);
        let result_ref = result_ref();
        run_git(&self.source, &["update-ref", &result_ref, &self.result]);
        fs::remove_file(&self.bundle).expect("remove old bundle");
        let excluded = format!("^{}", self.base);
        run_git(
            &self.source,
            &[
                "bundle",
                "create",
                "--version=2",
                path(&self.bundle),
                &result_ref,
                &excluded,
            ],
        );
    }
}
