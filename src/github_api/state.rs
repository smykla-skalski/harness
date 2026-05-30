use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::Notify;

use super::{GitHubCache, GitHubRateBudget, GitHubUsageRecorder};

#[cfg(test)]
static GLOBAL_BUDGET_TEST_LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();

#[cfg(test)]
pub(crate) async fn acquire_global_budget_test_lock(
) -> std::sync::MutexGuard<'static, ()> {
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

impl Drop for InflightGuard {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.state.inflight.lock() {
            guard.remove(&self.key);
        }
        self.notify.notify_waiters();
    }
}

pub(super) fn global_state() -> Arc<GitHubApiState> {
    Arc::clone(GLOBAL_STATE.get_or_init(|| {
        Arc::new(GitHubApiState {
            budget: GitHubRateBudget::new(),
            cache: GitHubCache::new(),
            recorder: GitHubUsageRecorder::new(),
            inflight: Mutex::new(HashMap::new()),
        })
    }))
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
