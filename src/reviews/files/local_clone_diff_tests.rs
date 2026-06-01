//! Unit tests for [`super`]'s gix-backed unified-diff generator. Split out of
//! `local_clone_diff.rs` to keep that file under the 520-line cap; declared
//! there as `#[path = "local_clone_diff_tests.rs"] mod tests;` so `super::*`
//! still resolves the private helpers under test.

use super::*;
use crate::reviews::files::local_clone::LocalCloneRoot;
use crate::reviews::files::local_clone_runtime::{
    DiscardProgressSink, LocalCloneProgressSink, LocalCloneRuntime,
};
use std::sync::Arc;

// Write a fixed user identity into the repo's local config so commits don't
// fall back to ~/.gitconfig when a parallel test redirects HOME via
// temp_env::with_var.
fn set_test_user(repo_path: &std::path::Path) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(repo_path.join("config"))
        .expect("open repo config");
    writeln!(f, "[user]\n\tname = Test\n\temail = test@example.com").expect("write user config");
}

/// Build a bare source repo with two commits: c0 establishes the
/// initial state, c1 modifies one file, adds another, and deletes a
/// third. Returns (c0, c1) so the tests can drive the diff between
/// them.
fn make_two_commit_source(path: &std::path::Path) -> (gix::ObjectId, gix::ObjectId) {
    gix::init_bare(path).expect("init bare");
    set_test_user(path);
    let repo = gix::open(path).expect("reopen bare");

    // c0: alpha.txt + delete-me.txt
    let alpha_v0 = repo
        .write_blob(b"alpha v0\nshared line\n" as &[u8])
        .expect("alpha v0")
        .detach();
    let delete_me = repo
        .write_blob(b"to delete\n" as &[u8])
        .expect("delete-me blob")
        .detach();
    let mut tree0 = gix::objs::Tree::empty();
    tree0.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "alpha.txt".into(),
        oid: alpha_v0,
    });
    tree0.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "delete-me.txt".into(),
        oid: delete_me,
    });
    let tree0_oid = repo.write_object(&tree0).expect("tree0").detach();
    let c0 = repo
        .commit(
            "refs/heads/main",
            "c0",
            tree0_oid,
            Vec::<gix::ObjectId>::new(),
        )
        .expect("c0")
        .detach();

    // c1: alpha modified, beta added, delete-me removed.
    let alpha_v1 = repo
        .write_blob(b"alpha v1\nshared line\nnew line\n" as &[u8])
        .expect("alpha v1")
        .detach();
    let beta = repo
        .write_blob(b"beta one\nbeta two\n" as &[u8])
        .expect("beta")
        .detach();
    let mut tree1 = gix::objs::Tree::empty();
    tree1.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "alpha.txt".into(),
        oid: alpha_v1,
    });
    tree1.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "beta.txt".into(),
        oid: beta,
    });
    let tree1_oid = repo.write_object(&tree1).expect("tree1").detach();
    let c1 = repo
        .commit("refs/heads/main", "c1", tree1_oid, vec![c0])
        .expect("c1")
        .detach();
    (c0, c1)
}

#[tokio::test]
async fn compute_patches_emits_added_modified_deleted_rows() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (c0, c1) = make_two_commit_source(&source);

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
    let url = format!("file://{}", source.display());
    let ensured = runtime
        .ensure_clone_with_url("fixture/source", &url, "refs/heads/main", sink)
        .await
        .expect("ensure clone");

    let patches = compute_unified_patches(
        &ensured,
        &c0.to_hex().to_string(),
        &c1.to_hex().to_string(),
        None,
    )
    .await
    .expect("compute patches");

    // Three entries: alpha (modified), beta (added), delete-me (deleted)
    assert_eq!(patches.len(), 3);
    let by_path: std::collections::BTreeMap<_, _> =
        patches.into_iter().map(|p| (p.path.clone(), p)).collect();
    assert_eq!(by_path["alpha.txt"].status, ReviewFileChangeType::Modified);
    assert_eq!(by_path["beta.txt"].status, ReviewFileChangeType::Added);
    assert_eq!(
        by_path["delete-me.txt"].status,
        ReviewFileChangeType::Deleted
    );
    // Modified row has both additions and deletions.
    assert!(by_path["alpha.txt"].additions > 0);
    assert!(by_path["alpha.txt"].deletions > 0);
    // All served via local clone.
    for patch in by_path.values() {
        assert_eq!(patch.served_by, ReviewFileServedBy::LocalClone);
        assert!(!patch.truncated);
    }
}

#[tokio::test]
async fn compute_patches_respects_path_filter() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (c0, c1) = make_two_commit_source(&source);

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
    let url = format!("file://{}", source.display());
    let ensured = runtime
        .ensure_clone_with_url("fixture/source", &url, "refs/heads/main", sink)
        .await
        .expect("ensure clone");

    let patches = compute_unified_patches(
        &ensured,
        &c0.to_hex().to_string(),
        &c1.to_hex().to_string(),
        Some(&["beta.txt".to_string()]),
    )
    .await
    .expect("compute filtered");

    assert_eq!(patches.len(), 1);
    assert_eq!(patches[0].path, "beta.txt");
}

#[tokio::test]
async fn compute_patches_marks_binary_with_empty_patch() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    gix::init_bare(&source).expect("init");
    set_test_user(&source);
    let repo = gix::open(&source).expect("reopen");
    let mut bin = Vec::from(b"PNG-like\0\x01\x02\x03" as &[u8]);
    bin.extend_from_slice(&[0u8; 32]);
    let bin_oid = repo.write_blob(bin.as_slice()).expect("bin").detach();
    let mut tree = gix::objs::Tree::empty();
    tree.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "logo.png".into(),
        oid: bin_oid,
    });
    let tree_oid = repo.write_object(&tree).expect("tree").detach();
    let c0 = repo
        .commit(
            "refs/heads/main",
            "c0",
            tree_oid,
            Vec::<gix::ObjectId>::new(),
        )
        .expect("c0")
        .detach();

    let mut bin2 = Vec::from(b"PNG-other\0\xff\xfe\xfd" as &[u8]);
    bin2.extend_from_slice(&[0u8; 32]);
    let bin_oid_v2 = repo.write_blob(bin2.as_slice()).expect("bin2").detach();
    let mut tree1 = gix::objs::Tree::empty();
    tree1.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "logo.png".into(),
        oid: bin_oid_v2,
    });
    let tree1_oid = repo.write_object(&tree1).expect("tree1").detach();
    let c1 = repo
        .commit("refs/heads/main", "c1", tree1_oid, vec![c0])
        .expect("c1")
        .detach();

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
    let url = format!("file://{}", source.display());
    let ensured = runtime
        .ensure_clone_with_url("fixture/binary", &url, "refs/heads/main", sink)
        .await
        .expect("ensure");

    let patches = compute_unified_patches(
        &ensured,
        &c0.to_hex().to_string(),
        &c1.to_hex().to_string(),
        None,
    )
    .await
    .expect("compute");
    assert_eq!(patches.len(), 1);
    let p = &patches[0];
    assert_eq!(p.path, "logo.png");
    assert!(p.patch.is_empty());
    assert_eq!(p.additions, 0);
    assert_eq!(p.deletions, 0);
}

#[test]
fn looks_binary_detects_null_in_first_8kb() {
    assert!(looks_binary(b"hello\0world"));
    assert!(!looks_binary(b"plain text without nulls"));
    // NUL past 8KB shouldn't flip the bit.
    let mut payload = vec![b'a'; BINARY_SAMPLE_BYTES];
    payload.push(0u8);
    assert!(!looks_binary(&payload));
}

#[test]
fn count_add_del_skips_diff_header_lines() {
    let text = "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n";
    let (a, d) = count_add_del(text);
    assert_eq!(a, 1);
    assert_eq!(d, 1);
}

#[test]
fn count_add_del_handles_pure_addition() {
    let text = "@@ +1,3 @@\n+a\n+b\n+c\n";
    let (a, d) = count_add_del(text);
    assert_eq!(a, 3);
    assert_eq!(d, 0);
}
