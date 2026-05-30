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
//!   prevents two concurrent `ensure_clone` calls for the same repo from
//!   double-cloning.
//!
//! Progress is reported via a [`LocalCloneProgressSink`] that the daemon
//! adapter bridges to a WebSocket push event. The runtime emits coarse
//! `Started` / `Completed` / `Failed` events rather than gix's fine-grained
//! tree of percentage counters: the UI only needs to render a "cloning..."
//! state, not a precise progress bar.

pub(crate) mod diff;

#[cfg(test)]
mod tests;

use std::collections::BTreeMap;
use std::fs;
use std::io::Result as IoResult;
use std::path::{Path, PathBuf};
use std::process;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use chrono::Utc;
use gix::progress::Discard;
use gix::refspec;
use gix::refspec::parse::Operation as RefspecOperation;
use gix::remote::Direction;
use gix::remote::ref_map::Options as RefMapOptions;
use tokio::fs as tokio_fs;
use tokio::sync::Mutex;
use tokio::task::spawn_blocking;

use diff::LocalCloneFetchRef;

use super::local_clone::{
    LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey, Sensitive, pat_clone_url,
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
    #[error("gix diff failed: {0}")]
    Diff(String),
    #[error("merge base not found: {0}")]
    MergeBase(String),
    #[error("invalid fetch refspec: {0}")]
    RefSpec(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("join error: {0}")]
    Join(String),
}

/// Reporting and registry context threaded into [`LocalCloneRuntime::handle_ensure_result`]
/// so the finalizer stays within the argument budget.
struct EnsureContext<'a> {
    sink: Arc<dyn LocalCloneProgressSink>,
    repo_label: &'a str,
    operation: LocalCloneOperation,
    elapsed: Duration,
    key: &'a RepoKey,
    bare_path: PathBuf,
}

/// Per-process runtime that owns the on-disk clones root and the per-repo
/// mutex map. Construct one instance and share it via `Arc`.
#[derive(Debug)]
pub struct LocalCloneRuntime {
    root: LocalCloneRoot,
    locks: Mutex<BTreeMap<RepoKey, Arc<Mutex<()>>>>,
    registry_lock: Mutex<()>,
}

impl LocalCloneRuntime {
    #[must_use]
    pub fn new(root: LocalCloneRoot) -> Self {
        Self {
            root,
            locks: Mutex::new(BTreeMap::new()),
            registry_lock: Mutex::new(()),
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
        self.ensure_clone_refs_with_url(repo_full_name, url.expose(), &[], head_ref_name, sink)
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
        self.ensure_clone_refs_with_url(repo_full_name, clone_url, &[], head_ref_name, sink)
            .await
    }

    /// Same as [`ensure_clone_with_url`] but fetches additional exact refs
    /// into local tracking refs before resolving `head_ref_name`.
    ///
    /// Callers use this for PR heads and base refs such as
    /// `refs/pull/123/head`, which are not covered by the default
    /// `refs/heads/*` clone refspec.
    pub async fn ensure_clone_refs_with_url(
        self: &Arc<Self>,
        repo_full_name: &str,
        clone_url: &str,
        extra_refs: &[LocalCloneFetchRef],
        head_ref_name: &str,
        sink: Arc<dyn LocalCloneProgressSink>,
    ) -> Result<EnsuredClone, LocalCloneRuntimeError> {
        let key = RepoKey::new(repo_full_name);
        let bare_path = key.bare_path(&self.root.path);
        let repo_label = repo_full_name.to_string();
        let head_ref = head_ref_name.to_string();
        let extra_refspecs = extra_refs
            .iter()
            .map(LocalCloneFetchRef::refspec)
            .collect::<Vec<_>>();
        let lock = self.lock_for(&key).await;
        let _guard = lock.lock().await;

        ensure_root_dir(&self.root.path).await?;

        let operation = if bare_path.exists() {
            LocalCloneOperation::Fetch
        } else {
            LocalCloneOperation::Clone
        };
        sink.report(LocalCloneProgress::Started {
            repo_full_name: repo_label.clone(),
            operation,
        });

        let start = Instant::now();
        let task_url = clone_url.to_string();
        let task_path = bare_path.clone();
        let task_ref = head_ref.clone();
        let result = spawn_blocking(move || {
            run_ensure(operation, &task_url, &task_path, &task_ref, &extra_refspecs)
        })
        .await
        .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?;

        self.handle_ensure_result(
            result,
            EnsureContext {
                sink,
                repo_label: &repo_label,
                operation,
                elapsed: start.elapsed(),
                key: &key,
                bare_path,
            },
        )
        .await
    }

    async fn handle_ensure_result(
        &self,
        result: Result<String, LocalCloneRuntimeError>,
        context: EnsureContext<'_>,
    ) -> Result<EnsuredClone, LocalCloneRuntimeError> {
        let EnsureContext {
            sink,
            repo_label,
            operation,
            elapsed,
            key,
            bare_path,
        } = context;
        match result {
            Ok(head_oid) => {
                sink.report(LocalCloneProgress::Completed {
                    repo_full_name: repo_label.to_string(),
                    operation,
                    duration: elapsed,
                });
                self.update_registry_on_success(key, repo_label, &bare_path)
                    .await?;
                Ok(EnsuredClone {
                    bare_path,
                    head_oid,
                })
            }
            Err(error) => {
                sink.report(LocalCloneProgress::Failed {
                    repo_full_name: repo_label.to_string(),
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
        spawn_blocking(move || {
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
    /// and persist with a same-process mutex plus atomic rename so
    /// concurrent different-repo clones cannot lose each other's entries.
    async fn update_registry_on_success(
        &self,
        key: &RepoKey,
        repo_full_name: &str,
        bare_path: &Path,
    ) -> Result<(), LocalCloneRuntimeError> {
        let _guard = self.registry_lock.lock().await;
        let registry_path = self.root.registry_path();
        let bare_path = bare_path.to_path_buf();
        let key = key.clone();
        let repo_full_name = repo_full_name.to_string();
        spawn_blocking(move || {
            let mut registry = if registry_path.exists() {
                let raw = fs::read(&registry_path).unwrap_or_default();
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
            let body = serde_json::to_vec_pretty(&registry).map_err(|e| e.to_string())?;
            write_registry_atomically(&registry_path, &body)?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?
        .map_err(LocalCloneRuntimeError::Io)
    }
}

async fn ensure_root_dir(path: &Path) -> Result<(), LocalCloneRuntimeError> {
    if path.exists() {
        return Ok(());
    }
    tokio_fs::create_dir_all(path)
        .await
        .map_err(|e| LocalCloneRuntimeError::Io(e.to_string()))
}

/// Walk `path` recursively summing file sizes. Best-effort - any unreadable
/// entry is silently skipped. Returns 0 on root-level error.
fn directory_size(path: &Path) -> IoResult<u64> {
    fn walk(p: &Path) -> IoResult<u64> {
        let meta = fs::metadata(p)?;
        if meta.is_file() {
            return Ok(meta.len());
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

/// Synchronous gix wrapper executed inside `spawn_blocking`. Returns the OID
/// the requested ref resolves to after the clone or fetch completes.
fn run_ensure(
    operation: LocalCloneOperation,
    url: &str,
    bare_path: &PathBuf,
    head_ref: &str,
    extra_refspecs: &[String],
) -> Result<String, LocalCloneRuntimeError> {
    let interrupted = AtomicBool::new(false);
    match operation {
        LocalCloneOperation::Clone => {
            if let Some(parent) = bare_path.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| LocalCloneRuntimeError::Io(e.to_string()))?;
            }
            let mut prepare = gix::prepare_clone_bare(url, bare_path)
                .map_err(|e| LocalCloneRuntimeError::Clone(e.to_string()))?
                .with_fetch_options(fetch_options(extra_refspecs)?);
            let (_repo, _outcome) = prepare
                .fetch_only(Discard, &interrupted)
                .map_err(|e| LocalCloneRuntimeError::Clone(e.to_string()))?;
        }
        LocalCloneOperation::Fetch => {
            let repo =
                gix::open(bare_path).map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
            let remote = repo
                .find_remote("origin")
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
            let connection = remote
                .connect(Direction::Fetch)
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
            let prepare = connection
                .prepare_fetch(Discard, fetch_options(extra_refspecs)?)
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
            let _outcome = prepare
                .receive(Discard, &interrupted)
                .map_err(|e| LocalCloneRuntimeError::Fetch(e.to_string()))?;
        }
    }

    let repo = gix::open(bare_path).map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
    let oid = resolve_ref(&repo, head_ref)?;
    Ok(oid.to_hex().to_string())
}

fn fetch_options(extra_refspecs: &[String]) -> Result<RefMapOptions, LocalCloneRuntimeError> {
    let mut options = RefMapOptions::default();
    for refspec in extra_refspecs {
        let parsed = refspec::parse(refspec.as_str().into(), RefspecOperation::Fetch)
            .map_err(|error| LocalCloneRuntimeError::RefSpec(error.to_string()))?;
        options.extra_refspecs.push(parsed.to_owned());
    }
    Ok(options)
}

fn resolve_ref(
    repo: &gix::Repository,
    head_ref: &str,
) -> Result<gix::ObjectId, LocalCloneRuntimeError> {
    if let Ok(id) = gix::ObjectId::from_hex(head_ref.as_bytes()) {
        return Ok(id);
    }
    let mut reference = repo
        .find_reference(head_ref)
        .map_err(|_| LocalCloneRuntimeError::RefMissing(head_ref.to_string()))?;
    let id = reference
        .peel_to_id()
        .map_err(|e| LocalCloneRuntimeError::RefMissing(e.to_string()))?;
    Ok(id.detach())
}
