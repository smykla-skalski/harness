use std::fs;

use tempfile::tempdir;

use super::{default_group, default_suite, write_group, write_meshmetric_group, write_suite};

#[test]
fn lightweight_builders_round_trip_smoke() {
    let tempdir = tempdir().expect("create builders tempdir");
    let fixtures_dir = tempdir.path().join("fixtures");
    let suite_path = fixtures_dir.join("suite.md");
    let group_path = fixtures_dir.join("groups").join("g01.md");
    let meshmetric_path = fixtures_dir.join("groups").join("g02.md");

    write_suite(&suite_path);
    write_group(&group_path);
    write_meshmetric_group(&meshmetric_path, true);

    assert!(suite_path.exists());
    assert!(group_path.exists());
    assert!(
        fs::read_to_string(&meshmetric_path)
            .expect("read meshmetric group")
            .contains("kind: MeshService")
    );
    assert!(
        default_suite()
            .feature("builder-smoke")
            .build_markdown()
            .contains("suite_id: example.suite")
    );
    assert!(
        default_group()
            .story("builder smoke story")
            .build_markdown()
            .contains("group_id: g01")
    );
}
