use chrono::DateTime;

use harness_kernel::errors::{CliError, CliErrorKind};

use super::{ExternalProvider, ExternalSyncClient, ExternalSyncOperation};
use crate::external::TaskBoardExternalCreateIntent;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalProviderScopeIdentity {
    provider: ExternalProvider,
    scope_id: String,
}

impl ExternalProviderScopeIdentity {
    pub fn for_client(client: &dyn ExternalSyncClient) -> Self {
        let provider = client.provider();
        let resource_id = normalize_resource_id(provider, &client.scope_id());
        let role = if client.allows_push() {
            "write"
        } else if client.authoritative_review_inbox() {
            "authoritative_read"
        } else {
            "read"
        };
        let scope_id = format!(
            "v1:{}:{role}:{}:{resource_id}",
            provider_label(provider),
            resource_id.len()
        );
        Self { provider, scope_id }
    }

    #[must_use]
    pub const fn provider(&self) -> ExternalProvider {
        self.provider
    }

    #[must_use]
    pub fn scope_id(&self) -> &str {
        &self.scope_id
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ExternalProviderScopeHealth {
    #[default]
    Healthy,
    BackingOff,
    Attempting,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalProviderScopeAvailability {
    Ready,
    BackingOff,
    Fenced,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExternalProviderScopeState {
    pub base_revision: Option<String>,
    pub health: ExternalProviderScopeHealth,
    pub failure_count: u32,
    pub backoff_until: Option<String>,
}

impl ExternalProviderScopeState {
    /// # Errors
    /// Returns an error when a backoff/attempt deadline or `now` fails to parse as RFC 3339.
    pub fn availability_at(
        &self,
        now: &str,
    ) -> Result<ExternalProviderScopeAvailability, CliError> {
        match self.health {
            ExternalProviderScopeHealth::Healthy => Ok(ExternalProviderScopeAvailability::Ready),
            ExternalProviderScopeHealth::BackingOff => {
                self.deadline_is_active(now, "backoff").map(|active| {
                    if active {
                        ExternalProviderScopeAvailability::BackingOff
                    } else {
                        ExternalProviderScopeAvailability::Ready
                    }
                })
            }
            ExternalProviderScopeHealth::Attempting => {
                self.deadline_is_active(now, "attempt lease").map(|active| {
                    if active {
                        ExternalProviderScopeAvailability::Fenced
                    } else {
                        ExternalProviderScopeAvailability::Ready
                    }
                })
            }
        }
    }

    fn deadline_is_active(&self, now: &str, kind: &str) -> Result<bool, CliError> {
        let until = self.backoff_until.as_deref().ok_or_else(|| {
            CliErrorKind::workflow_parse(format!("task-board provider {kind} deadline is missing"))
        })?;
        let until = DateTime::parse_from_rfc3339(until).map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "task-board provider {kind} deadline '{until}' is invalid: {error}"
            ))
        })?;
        let now = DateTime::parse_from_rfc3339(now).map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "task-board provider {kind} comparison time '{now}' is invalid: {error}"
            ))
        })?;
        Ok(until > now)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalProviderScopeAttempt {
    provider: ExternalProvider,
    scope_id: String,
    fence_marker: String,
    created_scope: bool,
}

impl ExternalProviderScopeAttempt {
    #[must_use]
    pub fn new(
        provider: ExternalProvider,
        scope_id: String,
        fence_marker: String,
        created_scope: bool,
    ) -> Self {
        Self {
            provider,
            scope_id,
            fence_marker,
            created_scope,
        }
    }

    #[must_use]
    pub const fn provider(&self) -> ExternalProvider {
        self.provider
    }

    #[must_use]
    pub fn scope_id(&self) -> &str {
        &self.scope_id
    }

    #[must_use]
    pub fn fence_marker(&self) -> &str {
        &self.fence_marker
    }

    #[must_use]
    pub const fn created_scope(&self) -> bool {
        self.created_scope
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExternalProviderScopeAttemptDecision {
    Started(ExternalProviderScopeAttempt),
    BackingOff,
    Fenced,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalSyncScopeOutcomeKind {
    Succeeded,
    Failed,
    BackingOff,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalSyncScopeOutcome {
    pub provider: ExternalProvider,
    pub scope_id: String,
    pub kind: ExternalSyncScopeOutcomeKind,
    pub error_code: Option<String>,
    pub error: Option<String>,
}

impl ExternalSyncScopeOutcome {
    #[must_use]
    pub fn success(provider: ExternalProvider, scope_id: String) -> Self {
        Self {
            provider,
            scope_id,
            kind: ExternalSyncScopeOutcomeKind::Succeeded,
            error_code: None,
            error: None,
        }
    }

    #[must_use]
    pub fn failed(provider: ExternalProvider, scope_id: String, error: &CliError) -> Self {
        let message = error.details().map_or_else(
            || error.message(),
            |details| format!("{}; {details}", error.message()),
        );
        Self {
            provider,
            scope_id,
            kind: ExternalSyncScopeOutcomeKind::Failed,
            error_code: Some(error.code().to_owned()),
            error: Some(message),
        }
    }

    #[must_use]
    pub fn backing_off(provider: ExternalProvider, scope_id: String) -> Self {
        Self {
            provider,
            scope_id,
            kind: ExternalSyncScopeOutcomeKind::BackingOff,
            error_code: None,
            error: None,
        }
    }
}

#[derive(Debug)]
pub struct ExternalSyncBatch {
    pub operations: Vec<ExternalSyncOperation>,
    pub external_create_follow_ups: Vec<TaskBoardExternalCreateIntent>,
    pub scope_outcomes: Vec<ExternalSyncScopeOutcome>,
    /// Provider references the run left alone because more than one board item
    /// claims them, so a duplicated claim is reported rather than silently
    /// skipped or allowed to fail its whole scope.
    pub ambiguous_references: Vec<String>,
    pub first_provider_failure: Option<CliError>,
    pub terminal_error: Option<CliError>,
}

impl ExternalSyncBatch {
    /// # Errors
    /// Returns the batch's terminal error, or its first provider failure when every scope failed.
    pub fn into_completed(mut self) -> Result<Self, CliError> {
        if let Some(error) = self.terminal_error.take() {
            return Err(error);
        }
        if self.succeeded_scope_count() == 0
            && let Some(error) = self.first_provider_failure.take()
        {
            return Err(error);
        }
        Ok(self)
    }

    /// # Errors
    /// See [`Self::into_completed`].
    pub fn into_operations(self) -> Result<Vec<ExternalSyncOperation>, CliError> {
        self.into_completed().map(|batch| batch.operations)
    }

    #[must_use]
    pub fn attempted_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind != ExternalSyncScopeOutcomeKind::BackingOff)
            .count()
    }

    #[must_use]
    pub fn failed_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind == ExternalSyncScopeOutcomeKind::Failed)
            .count()
    }

    #[must_use]
    pub fn succeeded_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind == ExternalSyncScopeOutcomeKind::Succeeded)
            .count()
    }

    #[must_use]
    pub const fn result_scope_count(&self) -> usize {
        self.scope_outcomes.len()
    }

    #[must_use]
    pub fn backing_off_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind == ExternalSyncScopeOutcomeKind::BackingOff)
            .count()
    }
}

fn normalize_resource_id(provider: ExternalProvider, resource_id: &str) -> String {
    let resource_id = resource_id.trim();
    match provider {
        ExternalProvider::GitHub => resource_id.to_ascii_lowercase(),
    }
}

const fn provider_label(provider: ExternalProvider) -> &'static str {
    match provider {
        ExternalProvider::GitHub => "github",
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;

    use super::*;
    use crate::external::{ExternalSyncClient, ExternalTask, ExternalTaskRef, TaskBoardItem};

    #[test]
    fn normalized_scope_identity_separates_provider_resource_and_client_role() {
        let repository_sync = ScopeClient {
            provider: ExternalProvider::GitHub,
            scope_id: " Acme/Widgets ",
            allows_push: true,
            authoritative_review_inbox: false,
        };
        let inbox = ScopeClient {
            provider: ExternalProvider::GitHub,
            scope_id: "acme/widgets",
            allows_push: false,
            authoritative_review_inbox: false,
        };
        let repository_scope = ExternalProviderScopeIdentity::for_client(&repository_sync);
        let inbox_scope = ExternalProviderScopeIdentity::for_client(&inbox);

        assert_eq!(
            repository_scope.scope_id(),
            "v1:github:write:12:acme/widgets"
        );
        assert_eq!(inbox_scope.scope_id(), "v1:github:read:12:acme/widgets");
        assert_ne!(repository_scope, inbox_scope);
    }

    #[test]
    fn authoritative_review_reader_has_distinct_scope_role() {
        let shared_review = ScopeClient {
            provider: ExternalProvider::GitHub,
            scope_id: "org/repository",
            allows_push: false,
            authoritative_review_inbox: false,
        };
        let assigned_inbox = ScopeClient {
            provider: ExternalProvider::GitHub,
            scope_id: "org/repository",
            allows_push: false,
            authoritative_review_inbox: true,
        };

        let shared_scope = ExternalProviderScopeIdentity::for_client(&shared_review);
        let assigned_scope = ExternalProviderScopeIdentity::for_client(&assigned_inbox);

        assert_eq!(shared_scope.scope_id(), "v1:github:read:14:org/repository");
        assert_eq!(
            assigned_scope.scope_id(),
            "v1:github:authoritative_read:14:org/repository"
        );
        assert_ne!(shared_scope, assigned_scope);
    }

    #[test]
    fn attempt_deadline_comparison_error_names_attempt_lease() {
        let state = ExternalProviderScopeState {
            health: ExternalProviderScopeHealth::Attempting,
            backoff_until: Some("2026-07-16T10:15:00Z".into()),
            ..ExternalProviderScopeState::default()
        };

        let error = state
            .availability_at("not-a-timestamp")
            .expect_err("invalid comparison timestamp");

        assert!(
            error
                .message()
                .contains("provider attempt lease comparison time")
        );
    }

    struct ScopeClient {
        provider: ExternalProvider,
        scope_id: &'static str,
        allows_push: bool,
        authoritative_review_inbox: bool,
    }

    #[async_trait]
    impl ExternalSyncClient for ScopeClient {
        fn provider(&self) -> ExternalProvider {
            self.provider
        }

        fn scope_id(&self) -> String {
            self.scope_id.into()
        }

        fn allows_push(&self) -> bool {
            self.allows_push
        }

        fn authoritative_review_inbox(&self) -> bool {
            self.authoritative_review_inbox
        }

        async fn pull_tasks(&self) -> Result<Vec<ExternalTask>, CliError> {
            Ok(Vec::new())
        }

        async fn push_task(&self, item: &TaskBoardItem) -> Result<ExternalTaskRef, CliError> {
            Ok(ExternalTaskRef::new(self.provider, item.id.clone()))
        }
    }
}
