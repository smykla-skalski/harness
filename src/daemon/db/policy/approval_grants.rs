//! Durable persistence for `ApprovalGate` grants.
//!
//! A grant is keyed by (board item, action, canvas revision). At most one live
//! (unconsumed) grant exists per key, enforced by a partial unique index. The
//! evaluation path creates pending grants fire-and-forget; resolution routes
//! move them to approved/denied/revoked; dispatch reservation consumes an
//! approved grant exactly once.

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::{Executor, FromRow, Sqlite, query, query_as};
use uuid::Uuid;

use super::super::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{PolicyAction, PolicyApprovalGrant, PolicyApprovalState, PolicyReasonCode};
use crate::workspace::utc_now;

/// Fields needed to create a pending grant for an approval gate.
#[derive(Debug, Clone)]
pub(crate) struct NewApprovalGrant {
    pub board_item_id: String,
    pub action: PolicyAction,
    pub canvas_id: Option<String>,
    pub canvas_revision: u64,
    pub node_id: String,
    pub reason_code: PolicyReasonCode,
    pub expiry_seconds: Option<u64>,
}

const INSERT_GRANT_SQL: &str = "
INSERT INTO policy_approval_grants (
    id, board_item_id, action, canvas_id, canvas_revision, node_id, reason_code,
    state, resolved_by, resolved_at, consumed_at, expiry_seconds, created_at, updated_at
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', NULL, NULL, NULL, ?8, ?9, ?9)";

const SELECT_LIVE_GRANT_SQL: &str = "
SELECT id, board_item_id, action, canvas_id, canvas_revision, node_id, reason_code,
    state, resolved_by, resolved_at, consumed_at, expiry_seconds, created_at, updated_at
FROM policy_approval_grants
WHERE board_item_id = ?1 AND action = ?2 AND canvas_revision = ?3
  AND state IN ('pending', 'approved') AND consumed_at IS NULL
  AND (expiry_seconds IS NULL
       OR unixepoch(created_at) + expiry_seconds > unixepoch(?4))
LIMIT 1";

const SELECT_PENDING_GRANTS_SQL: &str = "
SELECT id, board_item_id, action, canvas_id, canvas_revision, node_id, reason_code,
    state, resolved_by, resolved_at, consumed_at, expiry_seconds, created_at, updated_at
FROM policy_approval_grants
WHERE state = 'pending' AND consumed_at IS NULL
  AND (expiry_seconds IS NULL
       OR unixepoch(created_at) + expiry_seconds > unixepoch(?1))
ORDER BY created_at ASC, id ASC";

const SELECT_GRANT_BY_ID_SQL: &str = "
SELECT id, board_item_id, action, canvas_id, canvas_revision, node_id, reason_code,
    state, resolved_by, resolved_at, consumed_at, expiry_seconds, created_at, updated_at
FROM policy_approval_grants
WHERE id = ?1";

const RESOLVE_GRANT_SQL: &str = "
UPDATE policy_approval_grants
SET state = ?2, resolved_by = ?3, resolved_at = ?4, updated_at = ?4
WHERE id = ?1 AND state = 'pending' AND consumed_at IS NULL
  AND (expiry_seconds IS NULL
       OR unixepoch(created_at) + expiry_seconds > unixepoch(?4))";

const REVOKE_GRANT_SQL: &str = "
UPDATE policy_approval_grants
SET state = 'revoked', resolved_by = ?2, resolved_at = ?3, updated_at = ?3
WHERE id = ?1 AND state IN ('pending', 'approved') AND consumed_at IS NULL
  AND (expiry_seconds IS NULL
       OR unixepoch(created_at) + expiry_seconds > unixepoch(?3))";

const CONSUME_GRANT_SQL: &str = "
UPDATE policy_approval_grants
SET consumed_at = ?2, updated_at = ?2
WHERE id = ?1 AND state = 'approved' AND consumed_at IS NULL
  AND (expiry_seconds IS NULL
       OR unixepoch(created_at) + expiry_seconds > unixepoch(?2))";

const RETIRE_INACTIVE_GRANTS_SQL: &str = "
UPDATE policy_approval_grants
SET consumed_at = ?4, updated_at = ?4
WHERE board_item_id = ?1 AND action = ?2 AND canvas_revision = ?3
  AND consumed_at IS NULL
  AND (state NOT IN ('pending', 'approved')
       OR (expiry_seconds IS NOT NULL
           AND unixepoch(created_at) + expiry_seconds <= unixepoch(?4)))";

const RESTORE_CONSUMED_GRANT_SQL: &str = "
UPDATE policy_approval_grants
SET consumed_at = NULL, updated_at = ?2
WHERE id = ?1 AND state = 'approved' AND consumed_at IS NOT NULL
  AND (expiry_seconds IS NULL
       OR unixepoch(created_at) + expiry_seconds > unixepoch(?2))";

impl AsyncDaemonDb {
    /// Return the live grant for `grant`'s key, creating a pending one when none
    /// exists.
    ///
    /// # Errors
    /// Returns [`CliError`] on serialization or SQL failure.
    pub(crate) async fn ensure_pending_approval_grant(
        &self,
        grant: &NewApprovalGrant,
    ) -> Result<PolicyApprovalGrant, CliError> {
        let now = utc_now();
        self.retire_inactive_approval_grants(grant, &now).await?;
        if let Some(existing) = self
            .live_approval_grant_at(
                &grant.board_item_id,
                grant.action,
                grant.canvas_revision,
                &now,
            )
            .await?
        {
            return Ok(existing);
        }
        let id = format!("policy-grant-{}", Uuid::new_v4().simple());
        insert_pending_grant_at(self.pool(), &id, grant, &now).await?;
        self.approval_grant(&id)
            .await?
            .ok_or_else(|| db_error("created approval grant vanished".to_string()))
    }

    /// The live (unconsumed) grant for a (board item, action, revision) key.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or decode failure.
    pub(crate) async fn live_approval_grant(
        &self,
        board_item_id: &str,
        action: PolicyAction,
        canvas_revision: u64,
    ) -> Result<Option<PolicyApprovalGrant>, CliError> {
        self.live_approval_grant_at(board_item_id, action, canvas_revision, &utc_now())
            .await
    }

    async fn live_approval_grant_at(
        &self,
        board_item_id: &str,
        action: PolicyAction,
        canvas_revision: u64,
        now: &str,
    ) -> Result<Option<PolicyApprovalGrant>, CliError> {
        let row: Option<ApprovalGrantRow> = query_as(SELECT_LIVE_GRANT_SQL)
            .bind(board_item_id)
            .bind(enum_to_snake(&action)?)
            .bind(revision_to_i64(canvas_revision))
            .bind(now)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("read live approval grant: {error}")))?;
        row.map(ApprovalGrantRow::into_grant).transpose()
    }

    /// One grant by id.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or decode failure.
    pub(crate) async fn approval_grant(
        &self,
        id: &str,
    ) -> Result<Option<PolicyApprovalGrant>, CliError> {
        let row: Option<ApprovalGrantRow> = query_as(SELECT_GRANT_BY_ID_SQL)
            .bind(id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("read approval grant: {error}")))?;
        row.map(ApprovalGrantRow::into_grant).transpose()
    }

    /// All pending, unconsumed grants awaiting a human decision.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or decode failure.
    pub(crate) async fn list_pending_approval_grants(
        &self,
    ) -> Result<Vec<PolicyApprovalGrant>, CliError> {
        self.list_pending_approval_grants_at(&utc_now()).await
    }

    async fn list_pending_approval_grants_at(
        &self,
        now: &str,
    ) -> Result<Vec<PolicyApprovalGrant>, CliError> {
        let rows: Vec<ApprovalGrantRow> = query_as(SELECT_PENDING_GRANTS_SQL)
            .bind(now)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("list pending approval grants: {error}")))?;
        rows.into_iter().map(ApprovalGrantRow::into_grant).collect()
    }

    /// Resolve a pending grant to approved or denied, recording the actor.
    ///
    /// # Errors
    /// Returns [`CliError`] when the grant is missing or already resolved.
    pub(crate) async fn resolve_approval_grant(
        &self,
        id: &str,
        approve: bool,
        actor: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        self.resolve_approval_grant_at(id, approve, actor, &utc_now())
            .await
    }

    async fn resolve_approval_grant_at(
        &self,
        id: &str,
        approve: bool,
        actor: &str,
        now: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        let state = if approve {
            PolicyApprovalState::Approved
        } else {
            PolicyApprovalState::Denied
        };
        let affected = query(RESOLVE_GRANT_SQL)
            .bind(id)
            .bind(enum_to_snake(&state)?)
            .bind(actor)
            .bind(now)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("resolve approval grant: {error}")))?
            .rows_affected();
        if affected == 0 {
            return Err(db_error(format!(
                "approval grant '{id}' is not pending or does not exist"
            )));
        }
        self.approval_grant(id)
            .await?
            .ok_or_else(|| db_error("resolved approval grant vanished".to_string()))
    }

    /// Revoke a live pending or approved grant, recording the actor.
    ///
    /// # Errors
    /// Returns [`CliError`] when the grant is missing, terminal, consumed, or
    /// expired.
    pub(crate) async fn revoke_approval_grant(
        &self,
        id: &str,
        actor: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        self.revoke_approval_grant_at(id, actor, &utc_now()).await
    }

    async fn revoke_approval_grant_at(
        &self,
        id: &str,
        actor: &str,
        now: &str,
    ) -> Result<PolicyApprovalGrant, CliError> {
        let affected = query(REVOKE_GRANT_SQL)
            .bind(id)
            .bind(actor)
            .bind(now)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("revoke approval grant: {error}")))?
            .rows_affected();
        if affected == 0 {
            return Err(db_error(format!(
                "approval grant '{id}' is not live or does not exist"
            )));
        }
        self.approval_grant(id)
            .await?
            .ok_or_else(|| db_error("revoked approval grant vanished".to_string()))
    }

    async fn retire_inactive_approval_grants(
        &self,
        grant: &NewApprovalGrant,
        now: &str,
    ) -> Result<(), CliError> {
        query(RETIRE_INACTIVE_GRANTS_SQL)
            .bind(&grant.board_item_id)
            .bind(enum_to_snake(&grant.action)?)
            .bind(revision_to_i64(grant.canvas_revision))
            .bind(now)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("retire inactive approval grants: {error}")))?;
        Ok(())
    }
}

/// Consume an approved grant on an existing transaction so the one-shot
/// transition is atomic with dispatch reservation. Returns true when consumed.
///
/// # Errors
/// Returns [`CliError`] on SQL failure.
pub(crate) async fn consume_approval_grant_in_tx<'a, E>(
    executor: E,
    id: &str,
) -> Result<bool, CliError>
where
    E: Executor<'a, Database = Sqlite>,
{
    consume_approval_grant_in_tx_at(executor, id, &utc_now()).await
}

pub(crate) async fn consume_approval_grant_in_tx_at<'a, E>(
    executor: E,
    id: &str,
    now: &str,
) -> Result<bool, CliError>
where
    E: Executor<'a, Database = Sqlite>,
{
    let affected = query(CONSUME_GRANT_SQL)
        .bind(id)
        .bind(now)
        .execute(executor)
        .await
        .map_err(|error| db_error(format!("consume approval grant in tx: {error}")))?
        .rows_affected();
    Ok(affected > 0)
}

pub(crate) async fn live_approval_grant_in_tx_at<'a, E>(
    executor: E,
    board_item_id: &str,
    action: PolicyAction,
    canvas_revision: u64,
    now: &str,
) -> Result<Option<PolicyApprovalGrant>, CliError>
where
    E: Executor<'a, Database = Sqlite>,
{
    let row: Option<ApprovalGrantRow> = query_as(SELECT_LIVE_GRANT_SQL)
        .bind(board_item_id)
        .bind(enum_to_snake(&action)?)
        .bind(revision_to_i64(canvas_revision))
        .bind(now)
        .fetch_optional(executor)
        .await
        .map_err(|error| db_error(format!("read live approval grant in tx: {error}")))?;
    row.map(ApprovalGrantRow::into_grant).transpose()
}

pub(crate) async fn restore_consumed_approval_grant_in_tx_at<'a, E>(
    executor: E,
    id: &str,
    now: &str,
) -> Result<bool, CliError>
where
    E: Executor<'a, Database = Sqlite>,
{
    let affected = query(RESTORE_CONSUMED_GRANT_SQL)
        .bind(id)
        .bind(now)
        .execute(executor)
        .await
        .map_err(|error| db_error(format!("restore consumed approval grant in tx: {error}")))?
        .rows_affected();
    Ok(affected > 0)
}

async fn insert_pending_grant_at<'a, E>(
    executor: E,
    id: &str,
    grant: &NewApprovalGrant,
    now: &str,
) -> Result<(), CliError>
where
    E: Executor<'a, Database = Sqlite>,
{
    query(INSERT_GRANT_SQL)
        .bind(id)
        .bind(&grant.board_item_id)
        .bind(enum_to_snake(&grant.action)?)
        .bind(grant.canvas_id.as_deref())
        .bind(revision_to_i64(grant.canvas_revision))
        .bind(&grant.node_id)
        .bind(enum_to_snake(&grant.reason_code)?)
        .bind(
            grant
                .expiry_seconds
                .and_then(|value| i64::try_from(value).ok()),
        )
        .bind(now)
        .execute(executor)
        .await
        .map_err(|error| db_error(format!("create approval grant: {error}")))?;
    Ok(())
}

fn revision_to_i64(revision: u64) -> i64 {
    i64::try_from(revision).unwrap_or(i64::MAX)
}

#[derive(Debug, Clone, FromRow)]
struct ApprovalGrantRow {
    id: String,
    board_item_id: String,
    action: String,
    canvas_id: Option<String>,
    canvas_revision: i64,
    node_id: String,
    reason_code: String,
    state: String,
    resolved_by: Option<String>,
    resolved_at: Option<String>,
    consumed_at: Option<String>,
    expiry_seconds: Option<i64>,
    created_at: String,
    updated_at: String,
}

impl ApprovalGrantRow {
    fn into_grant(self) -> Result<PolicyApprovalGrant, CliError> {
        Ok(PolicyApprovalGrant {
            id: self.id,
            board_item_id: self.board_item_id,
            action: snake_to_enum(&self.action)?,
            canvas_id: self.canvas_id,
            canvas_revision: u64::try_from(self.canvas_revision).unwrap_or(0),
            node_id: self.node_id,
            reason_code: snake_to_enum(&self.reason_code)?,
            state: snake_to_enum(&self.state)?,
            resolved_by: self.resolved_by,
            resolved_at: self.resolved_at,
            consumed_at: self.consumed_at,
            expiry_seconds: self
                .expiry_seconds
                .and_then(|value| u64::try_from(value).ok()),
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

fn enum_to_snake<T: Serialize>(value: &T) -> Result<String, CliError> {
    match serde_json::to_value(value) {
        Ok(Value::String(text)) => Ok(text),
        Ok(other) => Err(db_error(format!(
            "enum did not serialize to a string: {other}"
        ))),
        Err(error) => Err(db_error(format!("serialize enum: {error}"))),
    }
}

fn snake_to_enum<T: DeserializeOwned>(text: &str) -> Result<T, CliError> {
    serde_json::from_value(Value::String(text.to_owned()))
        .map_err(|error| db_error(format!("decode enum '{text}': {error}")))
}

#[cfg(test)]
#[path = "approval_grants_tests.rs"]
mod tests;
