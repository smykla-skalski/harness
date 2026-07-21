#![allow(
    dead_code,
    reason = "shared contract is consumed by follow-up provider recovery slices"
)]

use async_trait::async_trait;

use crate::errors::CliError;

use super::{ExternalProvider, ExternalTask};

/// Immutable provider-create input captured before the first remote side effect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExternalCreateRequest {
    item_id: String,
    create_key: String,
    title: String,
    body: String,
    provider_target: String,
}

impl ExternalCreateRequest {
    #[must_use]
    pub(crate) fn new(
        item_id: impl Into<String>,
        create_key: impl Into<String>,
        title: impl Into<String>,
        body: impl Into<String>,
        provider_target: impl Into<String>,
    ) -> Self {
        Self {
            item_id: item_id.into(),
            create_key: create_key.into(),
            title: title.into(),
            body: body.into(),
            provider_target: provider_target.into(),
        }
    }

    #[must_use]
    pub(crate) fn item_id(&self) -> &str {
        &self.item_id
    }

    #[must_use]
    pub(crate) fn create_key(&self) -> &str {
        &self.create_key
    }

    #[must_use]
    pub(crate) fn title(&self) -> &str {
        &self.title
    }

    #[must_use]
    pub(crate) fn body(&self) -> &str {
        &self.body
    }

    #[must_use]
    pub(crate) fn provider_target(&self) -> &str {
        &self.provider_target
    }
}

/// Result of probing a provider for an earlier create attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ExternalCreateProbe {
    Found(ExternalTask),
    Absent,
}

/// Fenced provider-scope lease available to long-running recovery operations.
#[async_trait]
pub(crate) trait ExternalCreateLease: Send + Sync {
    /// Renew and validate the current provider-scope lease.
    ///
    /// Provider implementations call this before every remote page or side effect.
    ///
    /// # Errors
    /// Returns `CliError` when the attempt is stale or the lease cannot be persisted.
    async fn renew(&self) -> Result<(), CliError>;
}

/// Provider capability for crash-safe external-create admission and recovery.
///
/// Only a durable `Started` decision may call [`Self::create_started`].
/// `recover_existing` never grants fresh create admission: GitHub recovery is
/// scan-only and an [`ExternalCreateProbe::Absent`] result remains blocked,
/// while Todoist may replay the identical request with the persisted create key.
/// Implementations can renew the supplied lease before every remote page or
/// side effect.
#[async_trait]
pub(crate) trait ExternalCreateRecoveryClient: Send + Sync {
    #[must_use]
    fn provider(&self) -> ExternalProvider;

    #[must_use]
    fn supports_target(&self, provider_target: &str) -> bool;

    /// Create a provider task after durable create admission returned `Started`.
    ///
    /// # Errors
    /// Returns provider, transport, or lease errors.
    async fn create_started(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalTask, CliError>;

    /// Recover an existing durable create attempt without widening admission.
    ///
    /// GitHub implementations only scan for the persisted marker. Todoist
    /// implementations may replay with `request.create_key()` as `X-Request-Id`.
    ///
    /// # Errors
    /// Returns provider, transport, parsing, or lease errors.
    async fn recover_existing(
        &self,
        request: &ExternalCreateRequest,
        lease: &dyn ExternalCreateLease,
    ) -> Result<ExternalCreateProbe, CliError>;

    /// Extract a provider create key and remove its hidden marker when present.
    ///
    /// Providers without embedded create markers safely report no key. Marker
    /// parsers return errors for malformed, noncanonical, or duplicate reserved
    /// markers so later pull deduplication cannot silently import them.
    ///
    /// # Errors
    /// Returns `CliError` when reserved marker evidence is invalid.
    fn extract_create_key(&self, _task: &mut ExternalTask) -> Result<Option<String>, CliError> {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use crate::task_board::{ExternalSyncClient, ExternalTaskRef, TaskBoardItem, TaskBoardStatus};

    #[tokio::test]
    async fn external_sync_client_defaults_to_no_create_recovery_capability() {
        let client: &dyn ExternalSyncClient = &DefaultSyncClient;

        assert!(client.external_create_recovery().is_none());
    }

    #[test]
    fn create_recovery_marker_extraction_defaults_to_no_key() {
        let recovery: &dyn ExternalCreateRecoveryClient = &NoMarkerRecoveryClient;
        let mut task = task_from_request(&request());

        assert_eq!(
            recovery
                .extract_create_key(&mut task)
                .expect("default marker extraction"),
            None
        );
    }

    #[tokio::test]
    async fn external_sync_client_exposes_an_object_safe_create_recovery_capability() {
        let client = CapableSyncClient {
            recovery: FakeRecoveryClient,
        };
        let client: &dyn ExternalSyncClient = &client;
        let recovery: &dyn ExternalCreateRecoveryClient = client
            .external_create_recovery()
            .expect("create recovery capability");
        let request = request();
        let lease = CountingLease::default();

        let created = recovery
            .create_started(&request, &lease)
            .await
            .expect("create started");
        let probe = recovery
            .recover_existing(&request, &lease)
            .await
            .expect("recover existing");
        let mut marked = created.clone();
        marked.body.push_str("\n<!-- create-key:create-key-1 -->");

        assert_eq!(recovery.provider(), ExternalProvider::Todoist);
        assert!(recovery.supports_target(request.provider_target()));
        assert_eq!(created.reference.external_id, request.item_id());
        assert_eq!(created.title, request.title());
        assert_eq!(created.body, request.body());
        assert_eq!(probe, ExternalCreateProbe::Found(created));
        assert_eq!(
            recovery
                .extract_create_key(&mut marked)
                .expect("extract create key")
                .as_deref(),
            Some(request.create_key())
        );
        assert_eq!(marked.body, request.body());
        assert_eq!(lease.renewals.load(Ordering::SeqCst), 2);
    }

    #[derive(Default)]
    struct CountingLease {
        renewals: AtomicUsize,
    }

    #[async_trait]
    impl ExternalCreateLease for CountingLease {
        async fn renew(&self) -> Result<(), CliError> {
            self.renewals.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    struct FakeRecoveryClient;

    #[async_trait]
    impl ExternalCreateRecoveryClient for FakeRecoveryClient {
        fn provider(&self) -> ExternalProvider {
            ExternalProvider::Todoist
        }

        fn supports_target(&self, provider_target: &str) -> bool {
            provider_target == "project-1"
        }

        async fn create_started(
            &self,
            request: &ExternalCreateRequest,
            lease: &dyn ExternalCreateLease,
        ) -> Result<ExternalTask, CliError> {
            lease.renew().await?;
            Ok(task_from_request(request))
        }

        async fn recover_existing(
            &self,
            request: &ExternalCreateRequest,
            lease: &dyn ExternalCreateLease,
        ) -> Result<ExternalCreateProbe, CliError> {
            lease.renew().await?;
            Ok(ExternalCreateProbe::Found(task_from_request(request)))
        }

        fn extract_create_key(&self, task: &mut ExternalTask) -> Result<Option<String>, CliError> {
            let marker = "\n<!-- create-key:create-key-1 -->";
            let Some(body) = task.body.strip_suffix(marker).map(ToOwned::to_owned) else {
                return Ok(None);
            };
            task.body = body;
            Ok(Some("create-key-1".to_owned()))
        }
    }

    struct NoMarkerRecoveryClient;

    #[async_trait]
    impl ExternalCreateRecoveryClient for NoMarkerRecoveryClient {
        fn provider(&self) -> ExternalProvider {
            ExternalProvider::GitHub
        }

        fn supports_target(&self, _provider_target: &str) -> bool {
            false
        }

        async fn create_started(
            &self,
            _request: &ExternalCreateRequest,
            _lease: &dyn ExternalCreateLease,
        ) -> Result<ExternalTask, CliError> {
            unreachable!("default marker test does not create")
        }

        async fn recover_existing(
            &self,
            _request: &ExternalCreateRequest,
            _lease: &dyn ExternalCreateLease,
        ) -> Result<ExternalCreateProbe, CliError> {
            unreachable!("default marker test does not recover")
        }
    }

    fn request() -> ExternalCreateRequest {
        ExternalCreateRequest::new(
            "task-1",
            "create-key-1",
            "Task title",
            "Task body",
            "project-1",
        )
    }

    fn task_from_request(request: &ExternalCreateRequest) -> ExternalTask {
        ExternalTask {
            reference: ExternalTaskRef::new(ExternalProvider::Todoist, request.item_id()),
            title: request.title().to_owned(),
            body: request.body().to_owned(),
            status: TaskBoardStatus::Backlog,
            project_id: Some(request.provider_target().to_owned()),
            updated_at: Some("revision-1".into()),
            ..ExternalTask::default()
        }
    }

    struct DefaultSyncClient;

    #[async_trait]
    impl ExternalSyncClient for DefaultSyncClient {
        fn provider(&self) -> ExternalProvider {
            ExternalProvider::GitHub
        }

        async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
            unreachable!("contract test does not pull")
        }

        async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
            unreachable!("contract test does not push")
        }
    }

    struct CapableSyncClient {
        recovery: FakeRecoveryClient,
    }

    #[async_trait]
    impl ExternalSyncClient for CapableSyncClient {
        fn provider(&self) -> ExternalProvider {
            ExternalProvider::Todoist
        }

        fn external_create_recovery(&self) -> Option<&dyn ExternalCreateRecoveryClient> {
            Some(&self.recovery)
        }

        async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
            unreachable!("contract test does not pull")
        }

        async fn push_task(&self, _item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
            unreachable!("contract test does not push")
        }
    }
}
