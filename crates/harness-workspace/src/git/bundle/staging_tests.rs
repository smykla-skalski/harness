use fs_err as fs;

use super::super::super::bundle_staging::staging_root_for_test;
use super::Fixture;

#[test]
fn repeated_crashed_verifier_staging_is_pruned_before_each_import_retry() {
    let fixture = Fixture::new(false);
    let plan = fixture.plan();
    let root = staging_root_for_test(&plan.coordinates);

    for crash in ["first", "second"] {
        let stale = root.join(crash);
        fs::create_dir_all(&stale).expect("seed crashed verifier staging");
        fs::write(stale.join("bundle"), vec![b'x'; 1024]).expect("seed staged bundle");

        plan.verify_and_import_objects(&fixture.bundle)
            .expect("retry must recover after a crashed verifier");

        assert!(
            fs::read_dir(&root)
                .expect("read staging root")
                .next()
                .is_none(),
            "staging root must retain no verifier crash remnants"
        );
    }

    plan.cleanup_import_ref()
        .expect("clean exact replay import ref");
    fixture.assert_untouched();
}
