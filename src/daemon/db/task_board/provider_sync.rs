use chrono::{DateTime, Duration};
use sqlx::{query, query_as};
use uuid::Uuid;

use crate::daemon::db::task_board::items::bump_change_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error};
use crate::task_board::ExternalProvider;
use crate::task_board::external::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeAvailability, ExternalProviderScopeHealth, ExternalProviderScopeState,
};

use super::ORCHESTRATOR_CHANGE_SCOPE;

const BACKOFF_BASE_SECONDS: u64 = 30;
const BACKOFF_MULTIPLIER: u64 = 4;
const BACKOFF_MAX_SECONDS: u64 = 600;
const ATTEMPT_LEASE_SECONDS: i64 = 900;
const ATTEMPT_HEALTH_PREFIX: &str = "attempting:";
type ProviderScopeRow = (Option<String>, String, i64, Option<String>);

impl AsyncDaemonDb {
    pub(crate) async fn task_board_provider_scope_state(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        query_as::<_, ProviderScopeRow>(
            "SELECT base_revision, health, failure_count, backoff_until
             FROM task_board_provider_scope_state
             WHERE provider = ?1 AND scope_id = ?2",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("read task-board provider scope: {error}")))?
        .map_or_else(
            || Ok(ExternalProviderScopeState::default()),
            decode_provider_scope_state,
        )
    }

    pub(crate) async fn begin_task_board_provider_scope_attempt(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
        now: &str,
    ) -> Result<ExternalProviderScopeAttemptDecision, CliError> {
        let attempt_deadline = deadline_from_seconds(now, ATTEMPT_LEASE_SECONDS)?;
        let mut transaction = self
            .begin_immediate_transaction("task board provider scope attempt")
            .await?;
        let row = query_as::<_, ProviderScopeRow>(
            "SELECT base_revision, health, failure_count, backoff_until
             FROM task_board_provider_scope_state
             WHERE provider = ?1 AND scope_id = ?2",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read task-board provider attempt: {error}")))?;
        let created_scope = row.is_none();
        let state = row.map_or_else(
            || Ok(ExternalProviderScopeState::default()),
            decode_provider_scope_state,
        )?;
        let decision = match state.availability_at(now)? {
            ExternalProviderScopeAvailability::Ready => None,
            ExternalProviderScopeAvailability::BackingOff => {
                Some(ExternalProviderScopeAttemptDecision::BackingOff)
            }
            ExternalProviderScopeAvailability::Fenced => {
                Some(ExternalProviderScopeAttemptDecision::Fenced)
            }
        };
        if let Some(decision) = decision {
            transaction
                .commit()
                .await
                .map_err(|error| db_error(format!("commit provider scope admission: {error}")))?;
            return Ok(decision);
        }
        let fence_marker = format!("{ATTEMPT_HEALTH_PREFIX}{}", Uuid::new_v4().simple());
        query(
            "INSERT INTO task_board_provider_scope_state (
                provider, scope_id, health, failure_count, backoff_until, updated_at
             ) VALUES (?1, ?2, ?3, 0, ?4, ?5)
             ON CONFLICT(provider, scope_id) DO UPDATE SET
                health = excluded.health,
                backoff_until = excluded.backoff_until,
                updated_at = excluded.updated_at",
        )
        .bind(provider_label(provider))
        .bind(scope_id)
        .bind(&fence_marker)
        .bind(attempt_deadline)
        .bind(now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("begin task-board provider attempt: {error}")))?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board provider attempt: {error}")))?;
        Ok(ExternalProviderScopeAttemptDecision::Started(
            ExternalProviderScopeAttempt::new(
                provider,
                scope_id.to_owned(),
                fence_marker,
                created_scope,
            ),
        ))
    }

    pub(crate) async fn renew_task_board_provider_scope_attempt(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        now: &str,
    ) -> Result<(), CliError> {
        let attempt_deadline = deadline_from_seconds(now, ATTEMPT_LEASE_SECONDS)?;
        let updated = query(
            "UPDATE task_board_provider_scope_state SET
                backoff_until = ?4, updated_at = ?5
             WHERE provider = ?1 AND scope_id = ?2 AND health = ?3",
        )
        .bind(provider_label(attempt.provider()))
        .bind(attempt.scope_id())
        .bind(attempt.fence_marker())
        .bind(attempt_deadline)
        .bind(now)
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("renew task-board provider attempt: {error}")))?
        .rows_affected();
        if updated == 1 {
            Ok(())
        } else {
            Err(stale_attempt_error(attempt))
        }
    }

    pub(crate) async fn complete_task_board_provider_scope_success(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        base_revision: Option<&str>,
        completed_at: &str,
    ) -> Result<(), CliError> {
        parse_timestamp(completed_at)?;
        let mut transaction = self
            .begin_immediate_transaction("task board provider scope success")
            .await?;
        let current = query_as::<_, (Option<String>, i64)>(
            "SELECT base_revision, failure_count FROM task_board_provider_scope_state
             WHERE provider = ?1 AND scope_id = ?2 AND health = ?3",
        )
        .bind(provider_label(attempt.provider()))
        .bind(attempt.scope_id())
        .bind(attempt.fence_marker())
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read task-board provider success fence: {error}")))?;
        let Some((current_revision, failure_count)) = current else {
            return Err(stale_attempt_error(attempt));
        };
        let changed = attempt.created_scope()
            || failure_count != 0
            || base_revision.is_some_and(|revision| current_revision.as_deref() != Some(revision));
        let updated = query(
            "UPDATE task_board_provider_scope_state SET
                base_revision = COALESCE(?4, base_revision),
                health = 'healthy', failure_count = 0,
                backoff_until = NULL, updated_at = ?5
             WHERE provider = ?1 AND scope_id = ?2 AND health = ?3",
        )
        .bind(provider_label(attempt.provider()))
        .bind(attempt.scope_id())
        .bind(attempt.fence_marker())
        .bind(base_revision)
        .bind(completed_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record task-board provider success: {error}")))?
        .rows_affected();
        if updated != 1 {
            return Err(stale_attempt_error(attempt));
        }
        if changed {
            bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board provider success: {error}")))
    }

    pub(crate) async fn complete_task_board_provider_scope_failure(
        &self,
        attempt: &ExternalProviderScopeAttempt,
        completed_at: &str,
    ) -> Result<ExternalProviderScopeState, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board provider scope failure")
            .await?;
        let current = query_as::<_, (Option<String>, i64)>(
            "SELECT base_revision, failure_count FROM task_board_provider_scope_state
             WHERE provider = ?1 AND scope_id = ?2 AND health = ?3",
        )
        .bind(provider_label(attempt.provider()))
        .bind(attempt.scope_id())
        .bind(attempt.fence_marker())
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("read task-board provider failure fence: {error}")))?;
        let Some((base_revision, failure_count)) = current else {
            return Err(stale_attempt_error(attempt));
        };
        let failure_count = u32::try_from(failure_count)
            .map_err(|error| db_error(format!("decode provider failure count: {error}")))?
            .saturating_add(1);
        let backoff_until = backoff_deadline(completed_at, failure_count)?;
        let updated = query(
            "UPDATE task_board_provider_scope_state SET
                health = 'backing_off', failure_count = ?4,
                backoff_until = ?5, updated_at = ?6
             WHERE provider = ?1 AND scope_id = ?2 AND health = ?3",
        )
        .bind(provider_label(attempt.provider()))
        .bind(attempt.scope_id())
        .bind(attempt.fence_marker())
        .bind(i64::from(failure_count))
        .bind(&backoff_until)
        .bind(completed_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("record task-board provider failure: {error}")))?
        .rows_affected();
        if updated != 1 {
            return Err(stale_attempt_error(attempt));
        }
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task-board provider failure: {error}")))?;
        Ok(ExternalProviderScopeState {
            base_revision,
            health: ExternalProviderScopeHealth::BackingOff,
            failure_count,
            backoff_until: Some(backoff_until),
        })
    }
}

fn decode_provider_scope_state(
    (base_revision, health, failure_count, backoff_until): ProviderScopeRow,
) -> Result<ExternalProviderScopeState, CliError> {
    let health = match health.as_str() {
        "healthy" => ExternalProviderScopeHealth::Healthy,
        "backing_off" => ExternalProviderScopeHealth::BackingOff,
        value
            if value
                .strip_prefix(ATTEMPT_HEALTH_PREFIX)
                .is_some_and(|token| !token.is_empty()) =>
        {
            ExternalProviderScopeHealth::Attempting
        }
        value => {
            return Err(db_error(format!(
                "decode task-board provider health '{value}'"
            )));
        }
    };
    Ok(ExternalProviderScopeState {
        base_revision,
        health,
        failure_count: u32::try_from(failure_count).map_err(|error| {
            db_error(format!("decode task-board provider failure count: {error}"))
        })?,
        backoff_until,
    })
}

fn stale_attempt_error(attempt: &ExternalProviderScopeAttempt) -> CliError {
    CliErrorKind::concurrent_modification(format!(
        "task-board provider scope attempt for '{}' is stale",
        attempt.scope_id()
    ))
    .into()
}
fn backoff_deadline(now: &str, failure_count: u32) -> Result<String, CliError> {
    let exponent = failure_count.saturating_sub(1).min(10);
    let multiplier = BACKOFF_MULTIPLIER.saturating_pow(exponent);
    let seconds = BACKOFF_BASE_SECONDS
        .saturating_mul(multiplier)
        .min(BACKOFF_MAX_SECONDS);
    let seconds = i64::try_from(seconds)
        .map_err(|error| db_error(format!("decode provider backoff seconds: {error}")))?;
    deadline_from_seconds(now, seconds)
}
fn deadline_from_seconds(now: &str, seconds: i64) -> Result<String, CliError> {
    let now = parse_timestamp(now)?;
    Ok((now + Duration::seconds(seconds))
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string())
}

fn parse_timestamp(value: &str) -> Result<DateTime<chrono::FixedOffset>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map_err(|error| db_error(format!("parse provider scope timestamp: {error}")))
}

const fn provider_label(provider: ExternalProvider) -> &'static str {
    match provider {
        ExternalProvider::GitHub => "github",
        ExternalProvider::Todoist => "todoist",
    }
}
