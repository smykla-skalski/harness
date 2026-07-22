use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use tokio::sync::{Mutex as AsyncMutex, Notify, OwnedMutexGuard, broadcast};

use super::{GitHubCache, GitHubDataChange, GitHubRateBudget, GitHubUsageRecorder};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_mins(1);
const DATA_CHANGE_CAPACITY: usize = 128;

#[cfg(test)]
static GLOBAL_BUDGET_TEST_LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();

#[cfg(test)]
pub(crate) async fn acquire_global_budget_test_lock() -> std::sync::MutexGuard<'static, ()> {
    let lock = GLOBAL_BUDGET_TEST_LOCK.get_or_init(|| std::sync::Mutex::new(()));
    let guard = lock.lock().expect("global budget test lock poisoned");
    global_state().budget.reset_for_test().await;
    guard
}

static GLOBAL_STATE: OnceLock<Arc<GitHubApiState>> = OnceLock::new();

pub(super) struct GitHubApiState {
    pub(super) budget: GitHubRateBudget,
    pub(super) cache: GitHubCache,
    pub(super) recorder: GitHubUsageRecorder,
    pub(super) http: Result<reqwest::Client, String>,
    data_revision: AtomicU64,
    data_revision_write: Mutex<()>,
    mutation_barrier: Arc<AsyncMutex<()>>,
    data_changes: broadcast::Sender<GitHubDataChange>,
    inflight: Mutex<HashMap<String, Arc<Notify>>>,
}

pub(super) enum InflightRole {
    Leader(InflightGuard),
    Follower(Arc<Notify>),
}

pub(super) struct InflightGuard {
    key: String,
    notify: Arc<Notify>,
    state: Arc<GitHubApiState>,
}

pub(crate) struct GitHubMutationGuard {
    state: Arc<GitHubApiState>,
    operation: String,
    remote_succeeded: bool,
    _barrier: OwnedMutexGuard<()>,
}

impl Drop for InflightGuard {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.state.inflight.lock() {
            guard.remove(&self.key);
        }
        self.notify.notify_waiters();
    }
}

impl GitHubMutationGuard {
    pub(crate) const fn mark_remote_success(&mut self) {
        self.remote_succeeded = true;
    }

    pub(super) const fn mark_remote_failure(&mut self) {
        self.remote_succeeded = false;
    }
}

impl Drop for GitHubMutationGuard {
    fn drop(&mut self) {
        if self.remote_succeeded {
            self.state.publish_data_change(&self.operation);
        }
    }
}

pub(super) fn global_state() -> Arc<GitHubApiState> {
    Arc::clone(GLOBAL_STATE.get_or_init(|| {
        let (data_changes, _) = broadcast::channel(DATA_CHANGE_CAPACITY);
        let cache = GitHubCache::new();
        #[cfg(not(test))]
        let data_revision = cache.data_revision();
        #[cfg(test)]
        let data_revision = 0;
        Arc::new(GitHubApiState {
            budget: GitHubRateBudget::new(),
            cache,
            recorder: GitHubUsageRecorder::new(),
            http: reqwest::Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .read_timeout(READ_TIMEOUT)
                .build()
                .map_err(|error| error.to_string()),
            data_revision: AtomicU64::new(data_revision),
            data_revision_write: Mutex::new(()),
            mutation_barrier: Arc::new(AsyncMutex::new(())),
            data_changes,
            inflight: Mutex::new(HashMap::new()),
        })
    }))
}

impl GitHubApiState {
    pub(super) fn data_revision(&self) -> u64 {
        self.data_revision.load(Ordering::Acquire)
    }

    pub(super) fn data_changes(&self) -> broadcast::Receiver<GitHubDataChange> {
        self.data_changes.subscribe()
    }

    async fn mutation_guard(self: &Arc<Self>, operation: &str) -> GitHubMutationGuard {
        let barrier = Arc::clone(&self.mutation_barrier).lock_owned().await;
        GitHubMutationGuard {
            state: Arc::clone(self),
            operation: operation.to_string(),
            remote_succeeded: false,
            _barrier: barrier,
        }
    }

    pub(super) fn publish_data_change(&self, operation: &str) {
        let _guard = self
            .data_revision_write
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let revision = self.data_revision.fetch_add(1, Ordering::AcqRel) + 1;
        self.persist_data_revision(revision);
        let _ = self.data_changes.send(GitHubDataChange {
            revision,
            operation: operation.to_string(),
        });
    }

    /// Advance the read generation so a user-requested sync's GitHub reads miss the
    /// cache and surface edits made directly on GitHub (a new assignee, a review
    /// request). Holds the mutation barrier while bumping, exactly as a real
    /// mutation does, so a projection holding `stable_data_revision_guard` never
    /// observes the revision move under it. Stays silent - no data-change broadcast,
    /// because a manual refresh is not a client-facing mutation.
    pub(super) async fn refresh_read_generation(&self) {
        let _barrier = self.mutation_barrier.lock().await;
        let _guard = self
            .data_revision_write
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let revision = self.data_revision.fetch_add(1, Ordering::AcqRel) + 1;
        self.persist_data_revision(revision);
    }

    fn republish_current_data_change(&self, operation: &str) {
        let _guard = self
            .data_revision_write
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let _ = self.data_changes.send(GitHubDataChange {
            revision: self.data_revision(),
            operation: operation.to_string(),
        });
    }

    #[cfg(not(test))]
    #[expect(
        clippy::cognitive_complexity,
        reason = "revision persistence quarantines disk data through a nested recovery path"
    )]
    fn persist_data_revision(&self, revision: u64) {
        if let Err(error) = self.cache.persist_data_revision(revision) {
            tracing::warn!(%error, revision, "persist github data revision");
            if let Err(error) = self.cache.disable_disk_after_revision_failure(revision) {
                tracing::warn!(%error, revision, "disable stale github disk cache");
            }
        }
    }

    #[cfg(test)]
    const fn persist_data_revision(&self, _revision: u64) {}
}

pub(crate) async fn begin_external_mutation(operation: &str) -> GitHubMutationGuard {
    global_state().mutation_guard(operation).await
}

pub(crate) fn republish_current_data_change(operation: &str) {
    global_state().republish_current_data_change(operation);
}

pub(crate) async fn refresh_read_generation() {
    global_state().refresh_read_generation().await;
}

pub(crate) async fn stable_data_revision_guard(
    expected_revision: u64,
) -> Option<OwnedMutexGuard<()>> {
    let state = global_state();
    let guard = Arc::clone(&state.mutation_barrier).lock_owned().await;
    (state.data_revision() == expected_revision).then_some(guard)
}

pub(super) fn register_inflight(state: &Arc<GitHubApiState>, key: &str) -> InflightRole {
    let mut guard = state.inflight.lock().expect("github inflight lock");
    if let Some(notify) = guard.get(key) {
        return InflightRole::Follower(Arc::clone(notify));
    }
    let notify = Arc::new(Notify::new());
    guard.insert(key.to_string(), Arc::clone(&notify));
    InflightRole::Leader(InflightGuard {
        key: key.to_string(),
        notify,
        state: Arc::clone(state),
    })
}
