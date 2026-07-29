use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

type ManagedAgentMutationKey = (String, String);
type ManagedAgentMutationLane = Arc<AsyncMutex<()>>;
type ManagedAgentMutationMap = BTreeMap<ManagedAgentMutationKey, ManagedAgentMutationLane>;
type ManagedAgentMutationMapGuard<'a> = MutexGuard<'a, ManagedAgentMutationMap>;

#[derive(Clone, Default)]
pub struct ManagedAgentMutationLocks {
    inner: Arc<Mutex<ManagedAgentMutationMap>>,
}

impl ManagedAgentMutationLocks {
    pub async fn lock(&self, session_id: &str, agent_id: &str) -> ManagedAgentMutationGuard {
        let key = (session_id.to_string(), agent_id.to_string());
        let lock = {
            let mut inner = mutation_lock_map(&self.inner);
            inner
                .entry(key.clone())
                .or_insert_with(|| Arc::new(AsyncMutex::new(())))
                .clone()
        };
        let guard = lock.clone().lock_owned().await;
        ManagedAgentMutationGuard {
            key,
            lock,
            locks: self.clone(),
            guard: Some(guard),
        }
    }
}

#[must_use]
pub struct ManagedAgentMutationGuard {
    key: (String, String),
    lock: Arc<AsyncMutex<()>>,
    locks: ManagedAgentMutationLocks,
    guard: Option<OwnedMutexGuard<()>>,
}

impl Drop for ManagedAgentMutationGuard {
    fn drop(&mut self) {
        let Some(guard) = self.guard.take() else {
            return;
        };
        drop(guard);
        let mut inner = mutation_lock_map(&self.locks.inner);
        // Drop idle keys so the map reflects live contention instead of history.
        if Arc::strong_count(&self.lock) == 2 {
            inner.remove(&self.key);
        }
    }
}

fn mutation_lock_map(mutex: &Mutex<ManagedAgentMutationMap>) -> ManagedAgentMutationMapGuard<'_> {
    mutex
        .lock()
        .unwrap_or_else(recover_poisoned_mutation_lock_map)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn recover_poisoned_mutation_lock_map(
    error: PoisonError<ManagedAgentMutationMapGuard<'_>>,
) -> ManagedAgentMutationMapGuard<'_> {
    tracing::warn!(%error, "recovering poisoned managed-agent mutation map");
    error.into_inner()
}
