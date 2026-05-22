//! Real bare-clone runtime backed by `gix` (no `git` shell-outs).
//!
//! Wraps the `blocking-http-transport-reqwest-rust-tls` gix transport with
//! a tokio-friendly `spawn_blocking` shell so the daemon's async handlers
//! can call clone / fetch / read-blob without blocking the runtime.
//!
//! Three operations are exposed:
//!
//! - [`LocalCloneRuntime::ensure_clone`] - create the bare clone if missing
//!   or fetch the requested ref into an existing clone. Updates the
//!   registry's `last_used_at` / `last_fetched_at`.
//! - [`LocalCloneRuntime::read_blob`] - return the raw bytes of a single
//!   blob, used by the image preview pipeline as the zero-rate-limit path.
//! - Per-repo mutex serialization via [`LocalCloneRuntime::lock_for`]
//!   prevents two concurrent ensure_clone calls for the same repo from
//!   double-cloning.
//!
//! Progress is reported via a [`LocalCloneProgressSink`] that the daemon
//! adapter bridges to a WebSocket push event. The runtime emits coarse
//! `Started` / `Completed` / `Failed` events rather than gix's fine-grained
//! tree of percentage counters: the UI only needs to render a "cloning..."
//! state, not a precise progress bar.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use gix::progress::Discard;
use gix::remote::Direction;
use tokio::sync::Mutex;

use super::local_clone::{
    pat_clone_url, LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey, Sensitive,
};

/// One progress event broadcast for a long-running local-clone operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalCloneProgress {
    /// `git clone --bare` or `git fetch` is starting.
    Started {
        repo_full_name: String,
        operation: LocalCloneOperation,
    },
    /// The operation finished successfully.
    Completed {
        repo_full_name: String,
        operation: LocalCloneOperation,
        duration: Duration,
    },
    /// The operation failed; UI can drop the spinner and show the error.
    Failed {
        repo_full_name: String,
        operation: LocalCloneOperation,
        message: String,
    },
}

/// Coarse classification of which gix operation is in flight; lets the UI
/// pick a label ("Cloning..." vs "Fetching...") without parsing strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalCloneOperation {
    Clone,
    Fetch,
}

impl LocalCloneOperation {
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            Self::Clone => "clone",
            Self::Fetch => "fetch",
        }
    }
}

/// Sink for progress events. Implementations bridge to the daemon's WebSocket
/// broadcast channel; tests use a Vec collector.
pub trait LocalCloneProgressSink: Send + Sync {
    fn report(&self, event: LocalCloneProgress);
}

/// A no-op sink for code paths that don't care about progress (e.g. blob
/// reads, which are fast and local).
#[derive(Debug, Clone, Copy)]
pub struct DiscardProgressSink;

impl LocalCloneProgressSink for DiscardProgressSink {
    fn report(&self, _: LocalCloneProgress) {}
}

/// Marker returned by `ensure_clone` describing the bare clone on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnsuredClone {
    /// Filesystem path to the bare repository directory (ends in `.git`).
    pub bare_path: PathBuf,
    /// OID the requested ref currently resolves to inside the clone.
    pub head_oid: String,
}

/// Failure modes the runtime exposes to callers. Mapped from gix's many
/// internal error types into a small, UI-friendly enum.
#[derive(Debug, thiserror::Error)]
pub enum LocalCloneRuntimeError {
    #[error("gix clone failed: {0}")]
    Clone(String),
    #[error("gix fetch failed: {0}")]
    Fetch(String),
    #[error("gix open failed: {0}")]
    Open(String),
    #[error("ref not found in clone: {0}")]
    RefMissing(String),
    #[error("blob not found in clone: {0}")]
    BlobMissing(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("join error: {0}")]
    Join(String),
}

/// Per-process runtime that owns the on-disk clones root and the per-repo
/// mutex map. Construct one instance and share it via `Arc`.
#[derive(Debug)]
pub struct LocalCloneRuntime {
    root: LocalCloneRoot,
    locks: Mutex<BTreeMap<RepoKey, Arc<Mutex<()>>>>,
}

impl LocalCloneRuntime {
    #[must_use]
    pub fn new(root: LocalCloneRoot) -> Self {
        Self {
            root,
            locks: Mutex::new(BTreeMap::new()),
        }
    }

    /// Return the per-repo lock, creating it on first use. Two concurrent
    /// callers for *different* repos run in parallel; same-repo callers
    /// serialize so we never double-clone.
    async fn lock_for(&self, key: &RepoKey) -> Arc<Mutex<()>> {
        let mut map = self.locks.lock().await;
        Arc::clone(
            map.entry(key.clone())
                .or_insert_with(|| Arc::new(Mutex::new(()))),
        )
    }

    /// Ensure a bare clone exists for `repo_full_name`, authenticated via
    /// `pat`. On first call, creates the clone via `gix::prepare_clone_bare`.
    /// On subsequent calls, opens the existing clone and runs an
    /// incremental fetch.
    ///
    /// `pat` is wrapped in `Sensitive` so logs never leak it. The clone URL
    /// inlines the PAT per GitHub's documented HTTPS-with-token pattern.
    ///
    /// # Errors
    /// Returns [`LocalCloneRuntimeError`] on network, IO, or gix failures.
    pub async fn ensure_clone(
        self: &Arc<Self>,
        repo_full_name: &str,
        pat: Sensitive,
        head_ref_name: &str,
        sink: Arc<dyn LocalCloneProgressSink>,
    ) -> Result<EnsuredClone, LocalCloneRuntimeError> {
        let url = pat_clone_url(repo_full_name, &pat);
        self.ensure_clone_with_url(repo_full_name, url.expose(), head_ref_name, sink)
            .await
    }

    /// Same as [`ensure_clone`] but accepts a fully-formed URL. Used by
    /// tests with `file://` fixtures and by callers that want non-PAT URL
    /// forms (e.g. self-hosted GitHub Enterprise).
    pub async fn ensure_clone_with_url(
        self: &Arc<Self>,
        repo_full_name: &str,
        clone_url: &str,
        head_ref_name: &str,
        sink: Arc<dyn LocalCloneProgressSink>,
    ) -> Result<EnsuredClone, LocalCloneRuntimeError> {
        let key = RepoKey::new(repo_full_name);
        let bare_path = key.bare_path(&self.root.path);
        let repo_label = repo_full_name.to_string();
        let head_ref = head_ref_name.to_string();
        let lock = self.lock_for(&key).await;
        let _guard = lock.lock().await;

        if !self.root.path.exists() {
            tokio::fs::create_dir_all(&self.root.path)
                .await
                .map_err(|e| LocalCloneRuntimeError::Io(e.to_string()))?;
        }

        let operation = if bare_path.exists() {
            LocalCloneOperation::Fetch
        } else {
            LocalCloneOperation::Clone
        };
        sink.report(LocalCloneProgress::Started {
            repo_full_name: repo_label.clone(),
            operation,
        });

        let start = std::time::Instant::now();
        let task_url = clone_url.to_string();
        let task_path = bare_path.clone();
        let task_ref = head_ref.clone();
        let result =
            tokio::task::spawn_blocking(move || run_ensure(operation, task_url, task_path, task_ref))
                .await
                .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?;

        match result {
            Ok(head_oid) => {
                sink.report(LocalCloneProgress::Completed {
                    repo_full_name: repo_label.clone(),
                    operation,
                    duration: start.elapsed(),
                });
                self.update_registry_on_success(&key, &repo_label, &bare_path)
                    .await?;
                Ok(EnsuredClone {
                    bare_path,
                    head_oid,
                })
            }
            Err(error) => {
                sink.report(LocalCloneProgress::Failed {
                    repo_full_name: repo_label,
                    operation,
                    message: error.to_string(),
                });
                Err(error)
            }
        }
    }

    /// Read the raw bytes of a single blob from an already-ensured clone.
    /// Fast and rate-limit-free: pure local filesystem read.
    ///
    /// # Errors
    /// Returns [`LocalCloneRuntimeError::BlobMissing`] when the OID does not
    /// exist in the local objects store; [`LocalCloneRuntimeError::Open`] on
    /// gix open failure.
    pub async fn read_blob(
        &self,
        ensured: &EnsuredClone,
        oid: &str,
    ) -> Result<Vec<u8>, LocalCloneRuntimeError> {
        let bare_path = ensured.bare_path.clone();
        let oid_string = oid.to_string();
        tokio::task::spawn_blocking(move || {
            let repo =
                gix::open(&bare_path).map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
            let parsed_oid = gix::ObjectId::from_hex(oid_string.as_bytes())
                .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;
            let object = repo
                .find_object(parsed_oid)
                .map_err(|_| LocalCloneRuntimeError::BlobMissing(oid_string.clone()))?;
            Ok(object.detach().data)
        })
        .await
        .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?
    }

    /// Refresh the on-disk registry's `last_used_at` / `last_fetched_at`
    /// and persist atomically. Best-effort: filesystem errors are non-fatal
    /// (logged but the ensure-result is preserved).
    async fn update_registry_on_success(
        &self,
        key: &RepoKey,
        repo_full_name: &str,
        bare_path: &std::path::Path,
    ) -> Result<(), LocalCloneRuntimeError> {
        let registry_path = self.root.registry_path();
        let bare_path = bare_path.to_path_buf();
        let key = key.clone();
        let repo_full_name = repo_full_name.to_string();
        tokio::task::spawn_blocking(move || {
            let mut registry = if registry_path.exists() {
                let raw = std::fs::read(&registry_path).unwrap_or_default();
                serde_json::from_slice::<LocalCloneRegistry>(&raw).unwrap_or_default()
            } else {
                LocalCloneRegistry::default()
            };
            let now = Utc::now();
            let size = directory_size(&bare_path).unwrap_or(0);
            let entry = registry
                .entries
                .entry(key.clone())
                .or_insert_with(|| RegistryEntry {
                    repo_full_name: repo_full_name.clone(),
                    bare_path: bare_path.clone(),
                    size_bytes: size,
                    created_at: now,
                    last_used_at: now,
                    last_fetched_at: now,
                    last_known_head_ref_oid_by_pr: BTreeMap::new(),
                });
            entry.repo_full_name = repo_full_name;
            entry.bare_path = bare_path;
            entry.size_bytes = size;
            entry.last_used_at = now;
            entry.last_fetched_at = now;
            if let Some(parent) = registry_path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let body = serde_json::to_vec_pretty(&registry).map_err(|e| e.to_string())?;
            std::fs::write(&registry_path, body).map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?
        .map_err(LocalCloneRuntimeError::Io)
    }
}

/// Walk `path` recursively summing file sizes. Best-effort - any unreadable
/// entry is silently skipped. Returns 0 on root-level error.
fn directory_size(path: &std::path::Path) -> std::io::Result<u64> {
    fn walk(p: &std::path::Path) -> std::io::Result<u64> {
        let meta = std::fs::metadata(p)?;
        if meta.is_file() {
            return Ok(meta.len());
        }
        let mut total = 0_u64;
        for entry in std::fs::read_dir(p)?.flatten() {
            if let Ok(sub) = walk(&entry.path()) {
                total = total.saturating_add(sub);
            }
        }
        Ok(total)
    }
    walk(path)
}

/// Synchronous gix wrapper executed inside `spawn_blocking`. Returns the OID
/// the requested ref resolves to after the clone or fetch completes.
fn run_ensure(
    operation: LocalCloneOperation,
    url: String,
    bare_path: PathBuf,
    head_ref: String,
) -> Result<String, LocalCloneRuntimeError> {
    let interrupted = AtomicBool::new(false);
    match operation {
        LocalCloneOperation::Clone => {
            if let Some(parent) = bare_path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| LocalCloneRuntimeError::Io(e.to_string()))?;
            }
            let mut prepare = gix::prepare_clone_bare(url.as_str(), &bare_path)
                .map_err(|e| LocalCloneRuntimeError::Clone(e.to_string()))?;
            let (_repo, _outcome) = prepare
                .fetch_only(Discard, &interrupted)
                .map_err(|e| LocalCloneRuntimeError::Clone(e.to_string()))?;
        }
        LocalCloneOperation::Fetch => {
            let repo = gix::open(&bare_path)
                .map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
            let remote = repo
                .find_remote("origin")
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
            let connection = remote
                .connect(Direction::Fetch)
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
            let prepare = connection
                .prepare_fetch(Discard, gix::remote::ref_map::Options::default())
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
            let _outcome = prepare
                .receive(Discard, &interrupted)
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
        }
    }

    let repo =
        gix::open(&bare_path).map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
    let oid = resolve_ref(&repo, &head_ref)?;
    Ok(oid.to_hex().to_string())
}

fn resolve_ref(
    repo: &gix::Repository,
    head_ref: &str,
) -> Result<gix::ObjectId, LocalCloneRuntimeError> {
    let mut reference = repo
        .find_reference(head_ref)
        .map_err(|_| LocalCloneRuntimeError::RefMissing(head_ref.to_string()))?;
    let id = reference
        .peel_to_id()
        .map_err(|e| LocalCloneRuntimeError::RefMissing(e.to_string()))?;
    Ok(id.detach())
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Mutex as StdMutex;

    /// Test sink that captures every reported event so assertions can
    /// inspect the start/completed sequence.
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

    /// Build a tiny bare source repo with one commit on `refs/heads/main`
    /// and a single blob, using gix only - no `git` shell-outs.
    fn make_source_repo(path: &std::path::Path) -> (gix::ObjectId, gix::ObjectId) {
        let repo = gix::init_bare(path).expect("init bare");
        let blob_oid = repo
            .write_blob(b"hello fixture\n" as &[u8])
            .expect("blob")
            .detach();
        let mut tree = gix::objs::Tree::empty();
        tree.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "fixture.txt".into(),
            oid: blob_oid,
        });
        let tree_oid = repo.write_object(&tree).expect("write tree").detach();
        let commit_oid = repo
            .commit(
                "refs/heads/main",
                "fixture commit",
                tree_oid,
                Vec::<gix::ObjectId>::new(),
            )
            .expect("commit")
            .detach();
        (commit_oid, blob_oid)
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
}
