use super::*;

#[test]
fn full_pack_inflated_bytes_accept_exact_total_and_reject_one_less() {
    let first = "a".repeat(40);
    let second = "b".repeat(40);
    let output = format!("{first} blob 5 5 12\n{second} blob 7 7 24\nnon delta: 2 objects\n");
    let exact = GitBundleContentLimits {
        inflated_object_bytes: 7,
        inflated_pack_bytes: 12,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    require_inflated_sizes(Path::new("/frozen"), output.as_bytes(), 2, "sha1", exact)
        .expect("exact inflated total");

    let short = GitBundleContentLimits {
        inflated_pack_bytes: 11,
        ..exact
    };
    require_inflated_sizes(Path::new("/frozen"), output.as_bytes(), 2, "sha1", short)
        .expect_err("one excess inflated byte");
}

#[test]
fn full_pack_rejects_one_object_byte_above_exact_limit() {
    let oid = "a".repeat(40);
    let output = format!("{oid} blob 8 8 12\nnon delta: 1 object\n");
    let limits = GitBundleContentLimits {
        inflated_object_bytes: 7,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    require_inflated_sizes(Path::new("/frozen"), output.as_bytes(), 1, "sha1", limits)
        .expect_err("one excess object byte");
}

#[test]
fn stale_quarantine_is_removed_before_restart_reuse() {
    let temp = tempfile::tempdir().expect("quarantine fixture");
    let root = temp.path().join("quarantine");
    std::fs::create_dir_all(&root).expect("stale quarantine");
    std::fs::write(root.join("stale.pack"), b"stale").expect("stale pack");

    reset_quarantine(temp.path(), &root).expect("restart cleanup");

    assert!(!root.join("stale.pack").exists());
    assert!(root.join("pack").is_dir());
}

#[test]
fn resource_limit_arithmetic_fails_closed() {
    let limits = GitBundleContentLimits {
        bundle_bytes: u64::MAX,
        ..GitBundleContentLimits::REMOTE_RESULT
    };
    process_limits(Path::new("/frozen"), limits).expect_err("resource overflow");
}
