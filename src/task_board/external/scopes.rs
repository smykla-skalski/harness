use chrono::DateTime;

use crate::errors::{CliError, CliErrorKind};

use super::{ExternalProvider, ExternalSyncOperation};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ExternalProviderScopeState {
    pub(crate) base_revision: Option<String>,
    pub(crate) failure_count: u32,
    pub(crate) backoff_until: Option<String>,
}

impl ExternalProviderScopeState {
    pub(crate) fn is_backing_off_at(&self, now: &str) -> Result<bool, CliError> {
        let Some(until) = self.backoff_until.as_deref() else {
            return Ok(false);
        };
        let until = DateTime::parse_from_rfc3339(until).map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "task-board provider backoff deadline '{until}' is invalid: {error}"
            ))
        })?;
        let now = DateTime::parse_from_rfc3339(now).map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "task-board provider backoff comparison time '{now}' is invalid: {error}"
            ))
        })?;
        Ok(until > now)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExternalSyncScopeOutcomeKind {
    Succeeded,
    Failed,
    BackingOff,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExternalSyncScopeOutcome {
    pub(crate) provider: ExternalProvider,
    pub(crate) scope_id: String,
    pub(crate) kind: ExternalSyncScopeOutcomeKind,
    pub(crate) error_code: Option<String>,
    pub(crate) error: Option<String>,
}

impl ExternalSyncScopeOutcome {
    pub(crate) fn success(provider: ExternalProvider, scope_id: String) -> Self {
        Self {
            provider,
            scope_id,
            kind: ExternalSyncScopeOutcomeKind::Succeeded,
            error_code: None,
            error: None,
        }
    }

    pub(crate) fn failed(provider: ExternalProvider, scope_id: String, error: &CliError) -> Self {
        Self {
            provider,
            scope_id,
            kind: ExternalSyncScopeOutcomeKind::Failed,
            error_code: Some(error.code().to_owned()),
            error: Some(error.message()),
        }
    }

    pub(crate) fn backing_off(provider: ExternalProvider, scope_id: String) -> Self {
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
pub(crate) struct ExternalSyncBatch {
    pub(crate) operations: Vec<ExternalSyncOperation>,
    pub(crate) scope_outcomes: Vec<ExternalSyncScopeOutcome>,
    pub(crate) first_provider_failure: Option<CliError>,
}

impl ExternalSyncBatch {
    pub(crate) fn into_completed(mut self) -> Result<Self, CliError> {
        if self.succeeded_scope_count() == 0
            && let Some(error) = self.first_provider_failure.take()
        {
            return Err(error);
        }
        Ok(self)
    }

    pub(crate) fn into_operations(self) -> Result<Vec<ExternalSyncOperation>, CliError> {
        self.into_completed().map(|batch| batch.operations)
    }

    pub(crate) fn attempted_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind != ExternalSyncScopeOutcomeKind::BackingOff)
            .count()
    }

    pub(crate) fn failed_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind == ExternalSyncScopeOutcomeKind::Failed)
            .count()
    }

    pub(crate) fn succeeded_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind == ExternalSyncScopeOutcomeKind::Succeeded)
            .count()
    }

    pub(crate) const fn result_scope_count(&self) -> usize {
        self.scope_outcomes.len()
    }

    pub(crate) fn backing_off_scope_count(&self) -> usize {
        self.scope_outcomes
            .iter()
            .filter(|outcome| outcome.kind == ExternalSyncScopeOutcomeKind::BackingOff)
            .count()
    }
}
