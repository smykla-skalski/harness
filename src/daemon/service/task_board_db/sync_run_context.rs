use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::task_board::external::TaskBoardSyncCoordinatorFence;

use super::sync_audit::{SyncExecutionMetrics, TaskBoardSyncAuditTrigger};

#[derive(Clone)]
pub(crate) struct TaskBoardSyncRunContext {
    trigger: TaskBoardSyncAuditTrigger,
    correlation_id: Option<String>,
    coordinator_fence: Option<Arc<dyn TaskBoardSyncCoordinatorFence>>,
    sync_failed_scopes: Option<Arc<AtomicBool>>,
}

impl TaskBoardSyncRunContext {
    pub(crate) fn requested() -> Self {
        Self {
            trigger: TaskBoardSyncAuditTrigger::Requested,
            correlation_id: None,
            coordinator_fence: None,
            sync_failed_scopes: None,
        }
    }

    pub(crate) fn orchestrator(
        run_id: Option<String>,
        coordinator_fence: Option<Arc<dyn TaskBoardSyncCoordinatorFence>>,
        sync_failed_scopes: Option<Arc<AtomicBool>>,
    ) -> Self {
        Self {
            trigger: TaskBoardSyncAuditTrigger::Orchestrator,
            correlation_id: run_id,
            coordinator_fence,
            sync_failed_scopes,
        }
    }

    pub(super) const fn trigger(&self) -> TaskBoardSyncAuditTrigger {
        self.trigger
    }

    pub(super) fn correlation_id(&self) -> Option<&str> {
        self.correlation_id.as_deref()
    }

    pub(super) fn coordinator_fence(&self) -> Option<Arc<dyn TaskBoardSyncCoordinatorFence>> {
        self.coordinator_fence.clone()
    }

    pub(super) fn observe_sync_metrics(&self, metrics: &SyncExecutionMetrics) {
        if metrics.failed_scope_count() > 0
            && let Some(signal) = &self.sync_failed_scopes
        {
            signal.store(true, Ordering::SeqCst);
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::errors::CliErrorKind;
    use crate::task_board::ExternalProvider;
    use crate::task_board::external::{ExternalSyncBatch, ExternalSyncScopeOutcome};

    use super::*;

    #[test]
    fn failed_provider_scope_sets_the_shared_run_signal() {
        let signal = Arc::new(AtomicBool::new(false));
        let context = TaskBoardSyncRunContext::orchestrator(None, None, Some(Arc::clone(&signal)));
        let error = CliErrorKind::workflow_io("provider unavailable").into();
        let batch = ExternalSyncBatch {
            operations: Vec::new(),
            external_create_follow_ups: Vec::new(),
            scope_outcomes: vec![ExternalSyncScopeOutcome::failed(
                ExternalProvider::Todoist,
                "scope-neutral".into(),
                &error,
            )],
            first_provider_failure: Some(error),
            terminal_error: None,
        };
        let mut metrics = SyncExecutionMetrics::default();
        metrics.capture(&batch);

        context.observe_sync_metrics(&metrics);

        assert!(signal.load(Ordering::SeqCst));
    }
}
