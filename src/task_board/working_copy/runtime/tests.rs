use super::*;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
struct RecordingSink {
    events: StdMutex<Vec<WorkingCopyProgress>>,
}

impl WorkingCopyProgressSink for RecordingSink {
    fn report(&self, event: WorkingCopyProgress) {
        self.events.lock().unwrap().push(event);
    }
}

impl RecordingSink {
    fn snapshot(&self) -> Vec<WorkingCopyProgress> {
        self.events.lock().unwrap().clone()
    }
}

fn set_test_user(repo_path: &Path) {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(repo_path.join("config"))
        .expect("open repo config");
    writeln!(f, "[user]\n\tname = Test\n\temail = test@example.com").expect("write user");
}

fn make_source_repo(path: &Path) -> gix::ObjectId {
    gix::init_bare(path).expect("init bare");
    set_test_user(path);
    let repo = gix::open(path).expect("reopen bare");
    let blob_oid = repo.write_blob(b"hello fixture\n").expect("blob").detach();
    let mut tree = gix::objs::Tree::empty();
    tree.entries.push(gix::objs::tree::Entry {
        mode: gix::objs::tree::EntryKind::Blob.into(),
        filename: "fixture.txt".into(),
        oid: blob_oid,
    });
    let tree_oid = repo.write_object(&tree).expect("tree").detach();
    repo.commit(
        "refs/heads/main",
        "fixture commit",
        tree_oid,
        Vec::<gix::ObjectId>::new(),
    )
    .expect("commit")
    .detach()
}

#[tokio::test]
async fn obtain_clones_checks_out_working_tree_then_reuses() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    make_source_repo(&source);

    let root = WorkingCopyRoot::new(dir.path().join("working-copies"));
    let runtime = Arc::new(WorkingCopyRuntime::new(root));
    let sink = Arc::new(RecordingSink::default());
    let url = format!("file://{}", source.display());

    let first = runtime
        .obtain_with_url(
            "fixture/source",
            url.clone(),
            true,
            sink.clone() as Arc<dyn WorkingCopyProgressSink>,
        )
        .await
        .expect("obtain")
        .expect("present");
    assert!(first.cloned);
    // A real working tree: the committed file is on disk, checked out.
    assert!(first.checkout_path.join("fixture.txt").exists());
    assert!(first.checkout_path.join(".git").exists());

    let events = sink.snapshot();
    assert!(matches!(
        events.first(),
        Some(WorkingCopyProgress::Started { .. })
    ));
    assert!(matches!(
        events.last(),
        Some(WorkingCopyProgress::Completed { .. })
    ));

    // Second obtain reuses the existing checkout - no clone, no events.
    let reuse_sink = Arc::new(RecordingSink::default());
    let second = runtime
        .obtain_with_url(
            "fixture/source",
            url,
            true,
            reuse_sink.clone() as Arc<dyn WorkingCopyProgressSink>,
        )
        .await
        .expect("obtain")
        .expect("present");
    assert!(!second.cloned);
    assert_eq!(second.checkout_path, first.checkout_path);
    assert!(reuse_sink.snapshot().is_empty());
}

#[tokio::test]
async fn partial_checkout_without_marker_is_not_reused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("source.git");
    make_source_repo(&source);
    let root = WorkingCopyRoot::new(dir.path().join("working-copies"));
    let runtime = Arc::new(WorkingCopyRuntime::new(root));
    let url = format!("file://{}", source.display());
    let sink: Arc<dyn WorkingCopyProgressSink> =
        Arc::new(super::super::progress::DiscardProgressSink);

    let first = runtime
        .obtain_with_url("fixture/source", url.clone(), true, sink.clone())
        .await
        .expect("obtain")
        .expect("present");
    // Simulate a clone the daemon died in the middle of: the `.git` tree is
    // present but the completion marker was never written.
    std::fs::remove_file(completion_marker(&first.checkout_path)).expect("remove marker");

    // Reuse must reject it - allow_clone:false now reports "not present".
    let absent = runtime
        .obtain_with_url("fixture/source", url.clone(), false, sink.clone())
        .await
        .expect("obtain");
    assert!(absent.is_none());

    // With cloning allowed the stale directory is cleared and recloned.
    let recloned = runtime
        .obtain_with_url("fixture/source", url, true, sink)
        .await
        .expect("obtain")
        .expect("present");
    assert!(recloned.cloned);
    assert!(completion_marker(&recloned.checkout_path).exists());
}

#[test]
fn redact_clone_url_secret_strips_the_token() {
    let raw = "failed to fetch https://x-access-token:ghp_secret123@github.com/owner/repo.git: 404";
    let redacted = redact_clone_url_secret(raw);
    assert!(!redacted.contains("ghp_secret123"));
    assert!(redacted.contains("x-access-token:***@github.com/owner/repo.git"));
}

#[test]
fn strip_clone_url_credential_yields_a_tokenless_url() {
    let raw = "[remote \"origin\"]\n\turl = https://x-access-token:ghp_secret@github.com/o/r.git\n";
    let stripped = strip_clone_url_credential(raw);
    assert!(!stripped.contains("ghp_secret"));
    assert!(!stripped.contains("x-access-token"));
    assert!(stripped.contains("url = https://github.com/o/r.git"));
}

#[tokio::test]
async fn obtain_without_allow_clone_returns_none_when_absent() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = WorkingCopyRoot::new(dir.path().join("working-copies"));
    let runtime = Arc::new(WorkingCopyRuntime::new(root));
    let sink: Arc<dyn WorkingCopyProgressSink> =
        Arc::new(super::super::progress::DiscardProgressSink);

    let outcome = runtime
        .obtain_with_url("fixture/missing", "file:///nonexistent".into(), false, sink)
        .await
        .expect("obtain");
    assert!(outcome.is_none());
}

#[tokio::test]
async fn a_panicked_clone_task_becomes_a_reportable_error() {
    let join_error = tokio::spawn(async { panic!("clone thread died") })
        .await
        .expect_err("panicked task yields a JoinError");

    let result = super::flatten_clone_join(Err(join_error));

    let error = result.expect_err("a panicked clone must not read as success");
    assert!(
        matches!(error, WorkingCopyRuntimeError::Join(_)),
        "expected Join, got {error:?}"
    );
}

#[tokio::test]
async fn a_successful_clone_task_stays_successful() {
    assert!(super::flatten_clone_join(Ok(Ok(()))).is_ok());
}
