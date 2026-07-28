use super::*;

use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};

use gix::refs::transaction::PreviousValue;

use super::diff::LocalCloneFetchRef;

#[derive(Default)]
struct RecordingSink {
    events: StdMutex<Vec<LocalCloneProgress>>,
}

impl LocalCloneProgressSink for RecordingSink {
    fn report(&self, event: LocalCloneProgress) {
        self.events.lock().unwrap().push(event);
    }
}

impl RecordingSink {
    fn snapshot(&self) -> Vec<LocalCloneProgress> {
        self.events.lock().unwrap().clone()
    }
}

// Write a fixed user identity into the repo's local config so commits don't
// fall back to ~/.gitconfig, which may be inaccessible when a parallel test
// temporarily redirects HOME via temp_env::with_var.
fn set_test_user(repo_path: &std::path::Path) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(repo_path.join("config"))
        .expect("open repo config");
    writeln!(f, "[user]\n\tname = Test\n\temail = test@example.com").expect("write user config");
}

fn commit_file(
    repo: &gix::Repository,
    ref_name: &str,
    message: &str,
    contents: &[u8],
    parents: Vec<gix::ObjectId>,
) -> (gix::ObjectId, gix::ObjectId) {
    let blob_oid = repo.write_blob(contents).expect("blob").detach();
    let mut tree = gix::objs::Tree::empty();
    tree.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "fixture.txt".into(),
        oid: blob_oid,
    });
    let tree_oid = repo.write_object(&tree).expect("write tree").detach();
    let commit_oid = repo
        .commit(ref_name, message, tree_oid, parents)
        .expect("commit")
        .detach();
    (commit_oid, blob_oid)
}

fn make_source_repo(path: &std::path::Path) -> (gix::ObjectId, gix::ObjectId) {
    gix::init_bare(path).expect("init bare");
    set_test_user(path);
    let repo = gix::open(path).expect("reopen bare");
    commit_file(
        &repo,
        "refs/heads/main",
        "fixture commit",
        b"hello fixture\n",
        Vec::new(),
    )
}

fn make_two_commit_source(path: &std::path::Path) -> (gix::ObjectId, gix::ObjectId) {
    gix::init_bare(path).expect("init bare");
    set_test_user(path);
    let repo = gix::open(path).expect("reopen bare");
    let (base_oid, _) = commit_file(
        &repo,
        "refs/heads/main",
        "base commit",
        b"hello fixture\n",
        Vec::new(),
    );
    repo.reference(
        "refs/heads/base",
        base_oid,
        PreviousValue::Any,
        "base branch",
    )
    .expect("base ref");
    let (head_oid, _) = commit_file(
        &repo,
        "refs/heads/main",
        "head commit",
        b"hello changed\nnew line\n",
        vec![base_oid],
    );
    (base_oid, head_oid)
}

#[tokio::test]
async fn ensure_clone_via_file_url_creates_bare_clone_and_resolves_ref() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (commit_oid, _) = make_source_repo(&source);

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let sink = Arc::new(RecordingSink::default());

    let url = format!("file://{}", source.display());
    let ensured = runtime
        .ensure_clone_with_url(
            "fixture/source",
            &url,
            "refs/heads/main",
            sink.clone() as Arc<dyn LocalCloneProgressSink>,
        )
        .await
        .expect("ensure clone");
    assert_eq!(ensured.head_oid, commit_oid.to_hex().to_string());
    assert!(ensured.bare_path.exists());

    let events = sink.snapshot();
    assert!(matches!(
        events.first(),
        Some(LocalCloneProgress::Started {
            operation: LocalCloneOperation::Clone,
            ..
        })
    ));
    assert!(matches!(
        events.last(),
        Some(LocalCloneProgress::Completed {
            operation: LocalCloneOperation::Clone,
            ..
        })
    ));
}

#[tokio::test]
async fn read_blob_returns_raw_bytes_from_existing_clone() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (_, blob_oid) = make_source_repo(&source);

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);

    let url = format!("file://{}", source.display());
    let ensured = runtime
        .ensure_clone_with_url("fixture/source", &url, "refs/heads/main", sink)
        .await
        .expect("ensure clone");
    let bytes = runtime
        .read_blob(&ensured, &blob_oid.to_hex().to_string())
        .await
        .expect("blob");
    assert_eq!(bytes, b"hello fixture\n");
}

#[tokio::test]
async fn ensure_clone_twice_reuses_existing_bare_dir_via_fetch_path() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (_, _) = make_source_repo(&source);

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let url = format!("file://{}", source.display());

    let sink1: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
    let _first = runtime
        .ensure_clone_with_url("fixture/source", &url, "refs/heads/main", sink1)
        .await
        .expect("first ensure");

    let sink2 = Arc::new(RecordingSink::default());
    let _second = runtime
        .ensure_clone_with_url(
            "fixture/source",
            &url,
            "refs/heads/main",
            sink2.clone() as Arc<dyn LocalCloneProgressSink>,
        )
        .await
        .expect("second ensure");
    let events = sink2.snapshot();
    assert!(matches!(
        events.first(),
        Some(LocalCloneProgress::Started {
            operation: LocalCloneOperation::Fetch,
            ..
        })
    ));
}

#[tokio::test]
async fn ensure_clone_refs_fetches_non_head_pull_ref() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (_, head_oid) = make_two_commit_source(&source);
    let repo = gix::open(&source).expect("open source");
    repo.reference("refs/pull/7/head", head_oid, PreviousValue::Any, "pull ref")
        .expect("pull ref");

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let pull_ref = LocalCloneFetchRef::github_pull_head(7);
    let url = format!("file://{}", source.display());
    let ensured = runtime
        .ensure_clone_refs_with_url(
            "fixture/source",
            &url,
            std::slice::from_ref(&pull_ref),
            &pull_ref.local_ref,
            Arc::new(DiscardProgressSink),
        )
        .await
        .expect("ensure clone");
    assert_eq!(ensured.head_oid, head_oid.to_hex().to_string());
}

#[tokio::test]
async fn diff_refs_returns_merge_base_patches_and_stats() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    let (base_oid, head_oid) = make_two_commit_source(&source);

    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
    let url = format!("file://{}", source.display());
    let base_ref = LocalCloneFetchRef::mirrored("refs/heads/base");
    let head_ref = LocalCloneFetchRef::mirrored("refs/heads/main");
    let ensured = runtime
        .ensure_clone_refs_with_url(
            "fixture/source",
            &url,
            &[base_ref.clone(), head_ref.clone()],
            &head_ref.local_ref,
            Arc::new(DiscardProgressSink),
        )
        .await
        .expect("ensure clone");
    let diff = runtime
        .diff_refs(&ensured, &base_ref.local_ref, &head_ref.local_ref, &[])
        .await
        .expect("diff refs");
    assert_eq!(diff.base_ref_oid, base_oid.to_hex().to_string());
    assert_eq!(diff.head_ref_oid, head_oid.to_hex().to_string());
    assert_eq!(diff.merge_base_oid, base_oid.to_hex().to_string());
    assert_eq!(diff.stats.files_changed, 1);
    assert_eq!(diff.stats.additions, 2);
    assert_eq!(diff.stats.deletions, 1);
    assert_eq!(diff.patches[0].path, "fixture.txt");
    assert!(diff.patches[0].patch.contains("+hello changed"));
}

#[tokio::test]
async fn registry_updates_preserve_parallel_different_repos() {
    let dir = tempfile::tempdir().expect("tempdir");
    let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
    let runtime = Arc::new(LocalCloneRuntime::new(clones_root.clone()));
    let repo_a = dir.path().join("a.git");
    let repo_b = dir.path().join("b.git");
    std::fs::create_dir_all(&repo_a).expect("repo a");
    std::fs::create_dir_all(&repo_b).expect("repo b");
    std::fs::write(repo_a.join("pack"), [0u8; 10]).expect("write a");
    std::fs::write(repo_b.join("pack"), [0u8; 20]).expect("write b");

    let task_a = {
        let runtime = Arc::clone(&runtime);
        let repo_a = repo_a.clone();
        tokio::spawn(async move {
            runtime
                .update_registry_on_success(&RepoKey::new("owner/a"), "owner/a", &repo_a)
                .await
        })
    };
    let task_b = {
        let runtime = Arc::clone(&runtime);
        let repo_b = repo_b.clone();
        tokio::spawn(async move {
            runtime
                .update_registry_on_success(&RepoKey::new("owner/b"), "owner/b", &repo_b)
                .await
        })
    };
    task_a.await.expect("join a").expect("registry a");
    task_b.await.expect("join b").expect("registry b");

    let raw = std::fs::read(clones_root.registry_path()).expect("registry");
    let registry: LocalCloneRegistry = serde_json::from_slice(&raw).expect("json");
    assert!(registry.entries.contains_key(&RepoKey::new("owner/a")));
    assert!(registry.entries.contains_key(&RepoKey::new("owner/b")));
}

#[test]
fn operation_label_round_trips() {
    assert_eq!(LocalCloneOperation::Clone.label(), "clone");
    assert_eq!(LocalCloneOperation::Fetch.label(), "fetch");
}

#[test]
fn discard_sink_swallows_events_without_panic() {
    let sink = DiscardProgressSink;
    sink.report(LocalCloneProgress::Started {
        repo_full_name: "x".into(),
        operation: LocalCloneOperation::Clone,
    });
}

#[test]
fn directory_size_sums_files_recursively() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(dir.path().join("a"), [0u8; 100]).expect("write");
    let sub = dir.path().join("sub");
    std::fs::create_dir_all(&sub).expect("mkdir");
    std::fs::write(sub.join("b"), [0u8; 250]).expect("write");
    let total = directory_size(dir.path()).expect("walk");
    assert_eq!(total, 350);
}

#[tokio::test]
async fn runtime_lock_for_returns_same_arc_per_key() {
    let runtime = LocalCloneRuntime::new(LocalCloneRoot::new(PathBuf::from("/tmp/x")));
    let key = RepoKey::new("owner/repo");
    let a = runtime.lock_for(&key).await;
    let b = runtime.lock_for(&key).await;
    assert!(Arc::ptr_eq(&a, &b));
}
