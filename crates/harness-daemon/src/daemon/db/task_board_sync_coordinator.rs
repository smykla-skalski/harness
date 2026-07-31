use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use crate::daemon::protocol::TaskBoardSyncResponse;

#[derive(Debug, Default)]
pub(super) struct TaskBoardSyncCoordinator {
    gate: Arc<AsyncMutex<()>>,
    state: Mutex<TaskBoardSyncState>,
}

#[derive(Debug, Default)]
struct TaskBoardSyncState {
    active: Option<Arc<AtomicBool>>,
    last_cancelled: bool,
    last_error: Option<String>,
    last_summary: Option<TaskBoardSyncResponse>,
    next_generation: u64,
    pending_generation: Option<u64>,
}

pub(crate) struct TaskBoardSyncPermit {
    coordinator: Arc<TaskBoardSyncCoordinator>,
    cancellation: Arc<AtomicBool>,
    generation: Option<u64>,
    completion_recorded: bool,
    _guard: OwnedMutexGuard<()>,
}

pub(crate) struct TaskBoardSyncStatus {
    pub(crate) active: bool,
    pub(crate) cancellation_requested: bool,
    pub(crate) cancelled: bool,
    pub(crate) error: Option<String>,
    pub(crate) summary: Option<TaskBoardSyncResponse>,
}

impl TaskBoardSyncCoordinator {
    pub(super) async fn begin(self: &Arc<Self>) -> TaskBoardSyncPermit {
        let guard = Arc::clone(&self.gate).lock_owned().await;
        self.permit(guard)
    }

    pub(super) fn cancel_active(&self) -> bool {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let pending = state.pending_generation.take().is_some();
        if pending {
            state.last_cancelled = true;
            state.last_error = None;
            state.last_summary = None;
        }
        let cancelled_active = state.active.as_ref().is_some_and(|signal| {
            signal.store(true, Ordering::SeqCst);
            true
        });
        pending || cancelled_active
    }

    pub(super) fn schedule_requested(&self) -> u64 {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(signal) = &state.active {
            signal.store(true, Ordering::SeqCst);
        }
        state.next_generation = state.next_generation.wrapping_add(1);
        let generation = state.next_generation;
        state.pending_generation = Some(generation);
        state.last_cancelled = false;
        state.last_error = None;
        state.last_summary = None;
        generation
    }

    pub(super) async fn begin_scheduled(
        self: &Arc<Self>,
        generation: u64,
    ) -> Option<TaskBoardSyncPermit> {
        let guard = Arc::clone(&self.gate).lock_owned().await;
        let cancellation = Arc::new(AtomicBool::new(false));
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.pending_generation != Some(generation) {
            return None;
        }
        state.pending_generation = None;
        state.active = Some(Arc::clone(&cancellation));
        drop(state);
        Some(TaskBoardSyncPermit {
            coordinator: Arc::clone(self),
            cancellation,
            generation: Some(generation),
            completion_recorded: false,
            _guard: guard,
        })
    }

    pub(super) fn status(&self) -> TaskBoardSyncStatus {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let cancellation_requested = state
            .active
            .as_ref()
            .is_some_and(|signal| signal.load(Ordering::SeqCst));
        TaskBoardSyncStatus {
            active: state.pending_generation.is_some() || state.active.is_some(),
            cancellation_requested,
            cancelled: state.last_cancelled,
            error: state.last_error.clone(),
            summary: state.last_summary.clone(),
        }
    }

    fn permit(self: &Arc<Self>, guard: OwnedMutexGuard<()>) -> TaskBoardSyncPermit {
        let cancellation = Arc::new(AtomicBool::new(false));
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .active = Some(Arc::clone(&cancellation));
        TaskBoardSyncPermit {
            coordinator: Arc::clone(self),
            cancellation,
            generation: None,
            completion_recorded: false,
            _guard: guard,
        }
    }
}

impl TaskBoardSyncPermit {
    pub(crate) fn cancellation(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.cancellation)
    }

    pub(crate) fn record_completion(
        &mut self,
        summary: Option<TaskBoardSyncResponse>,
        error: Option<String>,
    ) {
        let Some(generation) = self.generation else {
            return;
        };
        let mut state = self
            .coordinator
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if state.next_generation == generation {
            let cancelled = self.cancellation.load(Ordering::SeqCst);
            state.last_cancelled = cancelled;
            state.last_error = if cancelled { None } else { error };
            state.last_summary = if cancelled { None } else { summary };
        }
        self.completion_recorded = true;
    }
}

impl Drop for TaskBoardSyncPermit {
    fn drop(&mut self) {
        let mut state = self
            .coordinator
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(generation) = self.generation
            && !self.completion_recorded
            && state.next_generation == generation
        {
            let cancelled = self.cancellation.load(Ordering::SeqCst);
            state.last_cancelled = cancelled;
            state.last_error =
                (!cancelled).then(|| "task-board source refresh stopped unexpectedly".to_owned());
            state.last_summary = None;
        }
        if state
            .active
            .as_ref()
            .is_some_and(|signal| Arc::ptr_eq(signal, &self.cancellation))
        {
            state.active = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering;

    use super::*;

    #[tokio::test]
    async fn cancellation_is_scoped_to_the_active_permit() {
        let coordinator = Arc::new(TaskBoardSyncCoordinator::default());
        let first = coordinator.begin().await;

        assert!(coordinator.cancel_active());
        assert!(first.cancellation().load(Ordering::SeqCst));
        drop(first);
        assert!(!coordinator.cancel_active());

        let second = coordinator.begin().await;
        assert!(!second.cancellation().load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn permits_serialize_sync_runs() {
        let coordinator = Arc::new(TaskBoardSyncCoordinator::default());
        let first = coordinator.begin().await;
        let waiting = {
            let coordinator = Arc::clone(&coordinator);
            tokio::spawn(async move { coordinator.begin().await })
        };

        tokio::task::yield_now().await;
        assert!(!waiting.is_finished());
        drop(first);

        let second = waiting.await.expect("waiting sync should acquire permit");
        assert!(!second.cancellation().load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn scheduled_runs_coalesce_to_the_latest_generation() {
        let coordinator = Arc::new(TaskBoardSyncCoordinator::default());
        let active = coordinator.begin().await;
        let first_generation = coordinator.schedule_requested();
        let second_generation = coordinator.schedule_requested();

        drop(active);
        assert!(
            coordinator
                .begin_scheduled(first_generation)
                .await
                .is_none()
        );
        let mut latest = coordinator
            .begin_scheduled(second_generation)
            .await
            .expect("latest scheduled task should acquire permit");
        assert!(coordinator.status().active);
        latest.record_completion(None, None);
        drop(latest);
        let status = coordinator.status();
        assert!(!status.active);
        assert!(!status.cancelled);
        assert!(status.error.is_none());
        assert!(status.summary.is_none());
    }

    #[tokio::test]
    async fn cancellation_clears_a_pending_run() {
        let coordinator = Arc::new(TaskBoardSyncCoordinator::default());
        let active = coordinator.begin().await;
        let generation = coordinator.schedule_requested();

        let status = coordinator.status();
        assert!(status.active);
        assert!(status.cancellation_requested);
        assert!(!status.cancelled);
        assert!(coordinator.cancel_active());
        let status = coordinator.status();
        assert!(status.active);
        assert!(status.cancellation_requested);
        assert!(status.cancelled);
        drop(active);
        assert!(coordinator.begin_scheduled(generation).await.is_none());
        let status = coordinator.status();
        assert!(!status.active);
        assert!(status.cancelled);
    }
}
