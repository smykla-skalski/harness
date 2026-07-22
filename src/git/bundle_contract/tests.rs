use super::*;

#[test]
fn bundle_pack_contract_rejects_excess_objects_and_bytes() {
    let repository = Path::new("/frozen/repository");
    let two_objects = bundle(2);
    let one_object_limit = GitBundleContentLimits {
        max_bundle_bytes: 1024,
        max_pack_objects: 1,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    require_bounded_bundle(repository, &two_objects, one_object_limit)
        .expect_err("pack object limit must be exact");

    let one_object = bundle(1);
    let short_byte_limit = GitBundleContentLimits {
        max_bundle_bytes: u64::try_from(one_object.len() - 1).expect("test length"),
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    require_bounded_bundle(repository, &one_object, short_byte_limit)
        .expect_err("bundle byte limit must be exact");
}

#[test]
fn bundle_pack_contract_accepts_the_exact_boundary() {
    let repository = Path::new("/frozen/repository");
    let bytes = bundle(1);
    let limits = GitBundleContentLimits {
        max_bundle_bytes: u64::try_from(bytes.len()).expect("test length"),
        max_pack_objects: 1,
        ..GitBundleContentLimits::REMOTE_RESULT
    };

    require_bounded_bundle(repository, &bytes, limits).expect("exact pack boundary");
}

#[test]
fn delta_output_limit_matches_one_maximum_raw_entry() {
    let repository = Path::new("/frozen/repository");
    let limits = GitBundleContentLimits {
        max_changed_paths: 1,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    let oid = "a".repeat(40);
    let mut raw = format!(":100644 100644 {oid} {oid} M\0").into_bytes();
    raw.extend(std::iter::repeat_n(b'p', 4096));
    raw.push(0);
    let limit = delta_output_limit(repository, 40, limits).expect("derive exact delta limit");

    assert_eq!(u64::try_from(raw.len()).expect("test length"), limit);
    raw.push(b'x');
    assert_eq!(u64::try_from(raw.len()).expect("test length"), limit + 1);
}

#[test]
fn source_tree_output_accepts_exact_path_limit_and_rejects_one_more() {
    let repository = Path::new("/frozen/repository");
    let limits = GitBundleContentLimits {
        max_changed_paths: 2,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    let oid = "a".repeat(40);
    let mut rows = format!("100644 blob {oid}\tone\0").into_bytes();
    rows.extend_from_slice(format!("100755 blob {oid}\ttwo\0").as_bytes());
    assert_eq!(
        parse_tree(repository, &rows, 40, limits)
            .expect("exact source path boundary")
            .len(),
        2
    );
    rows.extend_from_slice(format!("120000 blob {oid}\tthree\0").as_bytes());
    parse_tree(repository, &rows, 40, limits).expect_err("one excess source path");
}

#[test]
fn source_tree_output_limit_exposes_one_extra_byte() {
    let repository = Path::new("/frozen/repository");
    let limits = GitBundleContentLimits {
        max_changed_paths: 1,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    let oid = "a".repeat(40);
    let mut row = format!("160000 commit {oid}\t").into_bytes();
    row.extend(std::iter::repeat_n(b'p', 4096));
    row.push(0);
    let limit = tree_output_limit(repository, 40, limits).expect("source tree output limit");

    assert_eq!(u64::try_from(row.len()).expect("test length"), limit);
    row.push(b'x');
    assert_eq!(u64::try_from(row.len()).expect("test length"), limit + 1);
}

fn bundle(objects: u32) -> Vec<u8> {
    let mut bytes = b"# v2 git bundle\n\nPACK".to_vec();
    bytes.extend_from_slice(&2_u32.to_be_bytes());
    bytes.extend_from_slice(&objects.to_be_bytes());
    bytes
}
