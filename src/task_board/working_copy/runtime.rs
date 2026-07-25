//! gix-backed runtime that obtains a full working copy (clone + checkout).
//!
//! Unlike the reviews bare/blobless clone, this produces a real working tree
//! valid as a session `origin`. Obtain is idempotent: a present, reusable
//! checkout is returned as-is (its `last_used_at` bumped so GC keeps it), and
//! is only cloned when missing and cloning is allowed. The per-repo mutex
//! serializes same-repo callers so two deliveries never double-clone.

use std::collections::BTreeMap;
use std::fs;
use std::io::Result as IoResult;
use std::path::{Path, PathBuf};
use std::process;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

use chrono::Utc;
use gix::progress::tree;
use tokio::fs as tokio_fs;
use tokio::sync::Mutex;
use tokio::task::{JoinError, spawn_blocking};

use super::clone_progress::CloneProgressReporter;
use super::progress::{WorkingCopyProgress, WorkingCopyProgressSink};
use super::{WorkingCopyKey, WorkingCopyRegistry, WorkingCopyRegistryEntry, WorkingCopyRoot};

/// Outcome of a successful obtain: the checkout path plus whether a fresh
/// clone happened (`false` means an existing copy was reused).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObtainedWorkingCopy {
    pub checkout_path: PathBuf,
    pub cloned: bool,
}

/// Failure modes the runtime exposes to callers.
#[derive(Debug, thiserror::Error)]
pub enum WorkingCopyRuntimeError {
    #[error("gix clone failed: {0}")]
    Clone(String),
    #[error("gix checkout failed: {0}")]
    Checkout(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("join error: {0}")]
    Join(String),
}

/// Per-process runtime that owns the on-disk working-copies root and the
/// per-repo mutex map. Construct one instance and share it via `Arc`.
#[derive(Debug)]
pub struct WorkingCopyRuntime {
    root: WorkingCopyRoot,
    locks: Mutex<BTreeMap<WorkingCopyKey, Arc<Mutex<()>>>>,
    registry_lock: Mutex<()>,
}

impl WorkingCopyRuntime {
    #[must_use]
    pub fn new(root: WorkingCopyRoot) -> Self {
        Self {
            root,
            locks: Mutex::new(BTreeMap::new()),
            registry_lock: Mutex::new(()),
        }
    }

    async fn lock_for(&self, key: &WorkingCopyKey) -> Arc<Mutex<()>> {
        let mut map = self.locks.lock().await;
        Arc::clone(
            map.entry(key.clone())
                .or_insert_with(|| Arc::new(Mutex::new(()))),
        )
    }

    /// Obtain a working copy for `repo_full_name`, authenticated via `token`.
    /// A present, reusable checkout is returned without touching the network.
    /// When missing, it is cloned only if `allow_clone` is set - otherwise
    /// `Ok(None)` signals "not present" so callers (delivery) can fall back to
    /// asking the user rather than triggering a surprise multi-minute clone.
    ///
    /// # Errors
    /// Returns [`WorkingCopyRuntimeError`] on network, IO, or gix failures.
    pub async fn obtain(
        self: &Arc<Self>,
        repo_full_name: &str,
        token: &str,
        allow_clone: bool,
        sink: Arc<dyn WorkingCopyProgressSink>,
    ) -> Result<Option<ObtainedWorkingCopy>, WorkingCopyRuntimeError> {
        let url = format!("https://x-access-token:{token}@github.com/{repo_full_name}.git");
        self.obtain_with_url(repo_full_name, url, allow_clone, sink)
            .await
    }

    /// Same as [`obtain`] but accepts a fully-formed URL. Used by tests with
    /// `file://` fixtures. The URL may embed a secret, so it is never logged.
    ///
    /// # Errors
    /// Returns [`WorkingCopyRuntimeError`] on network, IO, or gix failures.
    #[expect(
        clippy::cognitive_complexity,
        reason = "obtain coordinates reuse detection, stale-checkout cleanup, clone gating, and progress reporting under one per-key lock"
    )]
    pub async fn obtain_with_url(
        self: &Arc<Self>,
        repo_full_name: &str,
        clone_url: String,
        allow_clone: bool,
        sink: Arc<dyn WorkingCopyProgressSink>,
    ) -> Result<Option<ObtainedWorkingCopy>, WorkingCopyRuntimeError> {
        let key = WorkingCopyKey::new(repo_full_name);
        let checkout_path = key.checkout_path(&self.root.path);
        let repo_label = repo_full_name.to_string();
        let lock = self.lock_for(&key).await;
        let _guard = lock.lock().await;

        ensure_root_dir(&self.root.path).await?;

        if is_reusable_checkout(&checkout_path).await {
            self.record_entry(&key, &repo_label, &checkout_path, false)
                .await?;
            return Ok(Some(ObtainedWorkingCopy {
                checkout_path,
                cloned: false,
            }));
        }
        if !allow_clone {
            return Ok(None);
        }
        // A leftover directory from a failed prior clone is not reusable;
        // clear it so the fresh clone starts clean.
        if checkout_path.exists() {
            tokio_fs::remove_dir_all(&checkout_path)
                .await
                .map_err(|error| WorkingCopyRuntimeError::Io(error.to_string()))?;
        }

        sink.report(WorkingCopyProgress::Started {
            repo_full_name: repo_label.clone(),
        });
        let start = Instant::now();
        let task_path = checkout_path.clone();
        let reporter = CloneProgressReporter::start(Arc::clone(&sink), repo_label.clone());
        let progress = reporter.progress();
        let joined =
            spawn_blocking(move || run_clone_checkout(&clone_url, &task_path, progress)).await;
        // Stop sampling before the terminal event, so no `Advanced` can arrive
        // after `Completed`/`Failed` and leave the UI stuck mid-progress.
        reporter.finish();
        let result = flatten_clone_join(joined);

        match result {
            Ok(()) => {
                sink.report(WorkingCopyProgress::Completed {
                    repo_full_name: repo_label.clone(),
                    duration: start.elapsed(),
                });
                self.record_entry(&key, &repo_label, &checkout_path, true)
                    .await?;
                Ok(Some(ObtainedWorkingCopy {
                    checkout_path,
                    cloned: true,
                }))
            }
            Err(error) => {
                let _ = tokio_fs::remove_dir_all(&checkout_path).await;
                sink.report(WorkingCopyProgress::Failed {
                    repo_full_name: repo_label,
                    message: error.to_string(),
                });
                Err(error)
            }
        }
    }

    /// Upsert the registry row and bump `last_used_at`. Recomputes the on-disk
    /// size only when a fresh clone happened or the row is new - the common
    /// reuse path just bumps the timestamp so it stays cheap on delivery.
    async fn record_entry(
        &self,
        key: &WorkingCopyKey,
        repo_full_name: &str,
        checkout_path: &Path,
        recompute_size: bool,
    ) -> Result<(), WorkingCopyRuntimeError> {
        let _guard = self.registry_lock.lock().await;
        let registry_path = self.root.registry_path();
        let checkout_path = checkout_path.to_path_buf();
        let key = key.clone();
        let repo_full_name = repo_full_name.to_string();
        spawn_blocking(move || {
            let mut registry = load_registry_lenient(&registry_path);
            let now = Utc::now();
            let existing = registry.entries.get(&key);
            let size = if recompute_size || existing.is_none() {
                directory_size(&checkout_path).unwrap_or(0)
            } else {
                existing.map_or(0, |entry| entry.size_bytes)
            };
            let created_at = existing.map_or(now, |entry| entry.created_at);
            registry.insert_or_update(
                key,
                WorkingCopyRegistryEntry {
                    repo_full_name,
                    checkout_path,
                    size_bytes: size,
                    created_at,
                    last_used_at: now,
                },
            );
            let body = serde_json::to_vec_pretty(&registry).map_err(|e| e.to_string())?;
            write_registry_atomically(&registry_path, &body)?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|join| WorkingCopyRuntimeError::Join(join.to_string()))?
        .map_err(WorkingCopyRuntimeError::Io)
    }

    /// Run `mutate` against the registry under the same lock and atomic-write
    /// path `record_entry` uses, so delete and GC never race obtain into a lost
    /// update or a torn file. The closure may also remove checkout directories;
    /// doing that inside the lock keeps a concurrent obtain from reusing a
    /// directory mid-delete.
    ///
    /// # Errors
    /// Returns [`WorkingCopyRuntimeError`] on IO, serialization, or join failures.
    pub async fn with_registry_mut<F, R>(&self, mutate: F) -> Result<R, WorkingCopyRuntimeError>
    where
        F: FnOnce(&mut WorkingCopyRegistry) -> R + Send + 'static,
        R: Send + 'static,
    {
        let _guard = self.registry_lock.lock().await;
        let registry_path = self.root.registry_path();
        spawn_blocking(move || {
            let mut registry = load_registry_lenient(&registry_path);
            let out = mutate(&mut registry);
            let body = serde_json::to_vec_pretty(&registry).map_err(|e| e.to_string())?;
            write_registry_atomically(&registry_path, &body)?;
            Ok::<R, String>(out)
        })
        .await
        .map_err(|join| WorkingCopyRuntimeError::Join(join.to_string()))?
        .map_err(WorkingCopyRuntimeError::Io)
    }
}

async fn ensure_root_dir(path: &Path) -> Result<(), WorkingCopyRuntimeError> {
    if path.exists() {
        return Ok(());
    }
    tokio_fs::create_dir_all(path)
        .await
        .map_err(|error| WorkingCopyRuntimeError::Io(error.to_string()))
}

/// Name of the completion marker written under `.git` once `main_worktree`
/// finishes. `gix::open` succeeds and `workdir()` is `Some` for a repo whose
/// fetch landed but whose checkout never ran - a clone the daemon died in the
/// middle of - so reuse keys off this marker, not off the repo's mere shape.
const COMPLETION_MARKER_NAME: &str = "harness-obtain-complete";

pub(crate) fn completion_marker(checkout_path: &Path) -> PathBuf {
    checkout_path.join(".git").join(COMPLETION_MARKER_NAME)
}

/// A directory is reusable only when the completion marker is present and gix
/// can open it as a repo with a working tree. A clone interrupted before the
/// checkout finished has no marker, so it reads as absent and gets recloned.
pub(crate) async fn is_reusable_checkout(path: &Path) -> bool {
    if !path.exists() {
        return false;
    }
    let path = path.to_path_buf();
    spawn_blocking(move || {
        completion_marker(&path).exists()
            && gix::open(&path).is_ok_and(|repo| repo.workdir().is_some())
    })
    .await
    .unwrap_or(false)
}

fn load_registry_lenient(registry_path: &Path) -> WorkingCopyRegistry {
    if !registry_path.exists() {
        return WorkingCopyRegistry::default();
    }
    let raw = match fs::read(registry_path) {
        Ok(raw) => raw,
        Err(error) => {
            warn_working_copy(&format!(
                "working-copy registry read failed, treating as empty: path={} error={error}",
                registry_path.display()
            ));
            return WorkingCopyRegistry::default();
        }
    };
    match serde_json::from_slice::<WorkingCopyRegistry>(&raw) {
        Ok(registry) => registry,
        Err(error) => {
            // A corrupt registry would otherwise be silently overwritten with an
            // empty one on the next write, orphaning every tracked checkout.
            // Preserve the bytes aside so the reset is diagnosable and reversible.
            let backup = registry_path.with_extension(format!("json.corrupt.{}", process::id()));
            let _ = fs::rename(registry_path, &backup);
            warn_working_copy(&format!(
                "working-copy registry parse failed, reset to empty (corrupt file kept at {}): error={error}",
                backup.display()
            ));
            WorkingCopyRegistry::default()
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn warn_working_copy(msg: &str) {
    tracing::warn!(target = "harness::task_board::working_copy", "{msg}");
}

/// Walk `path` recursively summing file sizes. Best-effort - any unreadable
/// entry is silently skipped.
fn directory_size(path: &Path) -> IoResult<u64> {
    fn walk(p: &Path) -> IoResult<u64> {
        let meta = fs::symlink_metadata(p)?;
        if meta.is_file() {
            return Ok(meta.len());
        }
        if !meta.is_dir() {
            return Ok(0);
        }
        let mut total = 0_u64;
        for entry in fs::read_dir(p)?.flatten() {
            if let Ok(sub) = walk(&entry.path()) {
                total = total.saturating_add(sub);
            }
        }
        Ok(total)
    }
    walk(path)
}

fn write_registry_atomically(registry_path: &Path, body: &[u8]) -> Result<(), String> {
    let parent = registry_path
        .parent()
        .ok_or_else(|| format!("registry path has no parent: {}", registry_path.display()))?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let tmp_path = registry_path.with_extension(format!("json.tmp.{}", process::id()));
    fs::write(&tmp_path, body).map_err(|e| e.to_string())?;
    fs::rename(&tmp_path, registry_path).map_err(|e| {
        let _ = fs::remove_file(&tmp_path);
        e.to_string()
    })?;
    Ok(())
}

/// Fold a panicked or cancelled clone task into an ordinary clone error.
///
/// A `JoinError` must not short-circuit past the caller's failure arm: a
/// consumer that has seen `Started` and a run of `Advanced` events has no way
/// to learn the clone died, and would render progress that never resolves.
fn flatten_clone_join(
    joined: Result<Result<(), WorkingCopyRuntimeError>, JoinError>,
) -> Result<(), WorkingCopyRuntimeError> {
    joined.unwrap_or_else(|join| Err(WorkingCopyRuntimeError::Join(join.to_string())))
}

/// Synchronous gix clone + checkout executed inside `spawn_blocking`.
fn run_clone_checkout(
    clone_url: &str,
    checkout_path: &Path,
    mut progress: tree::Item,
) -> Result<(), WorkingCopyRuntimeError> {
    if let Some(parent) = checkout_path.parent() {
        fs::create_dir_all(parent).map_err(|e| WorkingCopyRuntimeError::Io(e.to_string()))?;
    }
    let interrupted = AtomicBool::new(false);
    let mut prepare = gix::prepare_clone(clone_url, checkout_path)
        .map_err(|e| WorkingCopyRuntimeError::Clone(redact_clone_url_secret(&e.to_string())))?;
    // Both phases nest under the same item, so the sampler sees one tree
    // spanning fetch and checkout rather than two unrelated ones.
    let (mut checkout, _fetch) = prepare
        .fetch_then_checkout(&mut progress, &interrupted)
        .map_err(|e| WorkingCopyRuntimeError::Clone(redact_clone_url_secret(&e.to_string())))?;
    let (_repo, _outcome) = checkout
        .main_worktree(&mut progress, &interrupted)
        .map_err(|e| WorkingCopyRuntimeError::Checkout(redact_clone_url_secret(&e.to_string())))?;
    // gix records the fetch URL (token embedded) as remote.origin.url; scrub the
    // credential so it is not left at rest in the checkout's config.
    scrub_checkout_credential(checkout_path)?;
    // Mark completion only after the worktree is materialized and scrubbed; reuse
    // keys off this marker, never off the bare presence of a `.git` directory.
    fs::write(completion_marker(checkout_path), b"")
        .map_err(|e| WorkingCopyRuntimeError::Io(e.to_string()))?;
    Ok(())
}

/// Remove the `x-access-token:<token>@` credential gix persisted into the
/// checkout's `.git/config` (as `remote.origin.url`), leaving a valid tokenless
/// URL so the secret is not left at rest on disk. A no-op when the config has no
/// embedded credential.
fn scrub_checkout_credential(checkout_path: &Path) -> Result<(), WorkingCopyRuntimeError> {
    let config_path = checkout_path.join(".git").join("config");
    let Ok(contents) = fs::read_to_string(&config_path) else {
        return Ok(());
    };
    let scrubbed = strip_clone_url_credential(&contents);
    if scrubbed != contents {
        fs::write(&config_path, scrubbed).map_err(|e| WorkingCopyRuntimeError::Io(e.to_string()))?;
    }
    Ok(())
}

/// gix error strings can echo the clone URL, which carries the
/// `x-access-token:<token>@` credential. Replace it with `***` before the
/// message reaches a log line or the WS progress stream.
fn redact_clone_url_secret(message: &str) -> String {
    const MARKER: &str = "x-access-token:";
    let mut out = String::with_capacity(message.len());
    let mut rest = message;
    while let Some(idx) = rest.find(MARKER) {
        let after = idx + MARKER.len();
        out.push_str(&rest[..after]);
        if let Some(at) = rest[after..].find('@') {
            out.push_str("***");
            rest = &rest[after + at..];
        } else {
            rest = &rest[after..];
        }
    }
    out.push_str(rest);
    out
}

/// Remove `x-access-token:<token>@` entirely, yielding a valid tokenless URL
/// (unlike [`redact_clone_url_secret`], which keeps a `***` placeholder for log
/// readability). Used to rewrite the checkout's persisted remote URL.
fn strip_clone_url_credential(text: &str) -> String {
    const MARKER: &str = "x-access-token:";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(idx) = rest.find(MARKER) {
        if let Some(at) = rest[idx + MARKER.len()..].find('@') {
            out.push_str(&rest[..idx]);
            rest = &rest[idx + MARKER.len() + at + 1..];
        } else {
            let after = idx + MARKER.len();
            out.push_str(&rest[..after]);
            rest = &rest[after..];
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests;
