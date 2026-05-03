use std::collections::BTreeMap;
use std::mem;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use tokio::task::{AbortHandle, JoinHandle};
use tokio::time::sleep;

use super::{PermissionBridgeState, expire_batch, recover_lock};

pub(super) struct PermissionBridgeRuntime {
    pub(super) worker: Mutex<Option<JoinHandle<()>>>,
    expiration_tasks: Mutex<BTreeMap<String, AbortHandle>>,
}

impl PermissionBridgeRuntime {
    pub(super) fn new() -> Self {
        Self {
            worker: Mutex::new(None),
            expiration_tasks: Mutex::new(BTreeMap::new()),
        }
    }

    pub(super) fn cancel_expiration_task(&self, batch_id: &str) {
        if let Some(task) = recover_lock(
            &self.expiration_tasks,
            "permission bridge expiration task map lock",
        )
        .remove(batch_id)
        {
            task.abort();
        }
    }

    pub(super) fn abort_expiration_tasks(&self) {
        let tasks = mem::take(&mut *recover_lock(
            &self.expiration_tasks,
            "permission bridge expiration task map lock",
        ));
        for (_, task) in tasks {
            task.abort();
        }
    }

    fn clear_expiration_task(&self, batch_id: &str) {
        recover_lock(
            &self.expiration_tasks,
            "permission bridge expiration task map lock",
        )
        .remove(batch_id);
    }

    #[cfg(test)]
    pub(super) fn expiration_task_count(&self) -> usize {
        recover_lock(
            &self.expiration_tasks,
            "permission bridge expiration task map lock",
        )
        .len()
    }
}

pub(super) fn spawn_batch_expiration(
    state: Arc<PermissionBridgeState>,
    runtime_ref: &Weak<PermissionBridgeRuntime>,
    batch_id: String,
    deadline: Duration,
) {
    let Some(runtime) = runtime_ref.upgrade() else {
        return;
    };
    let mut expiration_tasks = recover_lock(
        &runtime.expiration_tasks,
        "permission bridge expiration task map lock",
    );
    let cleanup_runtime = Weak::clone(runtime_ref);
    let cleanup_batch_id = batch_id.clone();
    let task = tokio::spawn(async move {
        tokio::select! {
            biased;
            () = state.shutdown_notify.notified() => {}
            () = sleep(deadline) => {
                expire_batch(&state, &cleanup_batch_id);
            }
        }
        if let Some(runtime) = cleanup_runtime.upgrade() {
            runtime.clear_expiration_task(&cleanup_batch_id);
        }
    });
    // Register the abort handle while holding the map lock so a zero-deadline
    // task cannot finish and clear itself before its handle exists.
    expiration_tasks.insert(batch_id, task.abort_handle());
}
