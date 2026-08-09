use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_workspace::workspace::utc_now;
use sqlx::{Sqlite, SqlitePool, Transaction, query, query_as, query_scalar};

use crate::agent_workspaces::identity::digest_fields;

use super::model::WorkspaceMemberRegistration;

/// Join a managed worker to its workspace team at start.
///
/// The daemon started this process itself, so the member lands `joined` with a
/// `running` runtime rather than the `pending_registration` the legacy backfill
/// mints for a terminal it only inferred. `#1347`'s delayed-registration
/// reconciliation matches on the managed identity, so a later terminal join
/// updates this row instead of adding a second one.
pub(super) async fn register_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    registration: &WorkspaceMemberRegistration,
) -> Result<String, CliError> {
    bind_runtime_owner_in_tx(transaction, registration).await?;
    let member_id = registration.member_id();
    let now = utc_now();
    let evidence = format!("family={};status=started", registration.runtime_kind);
    let source_digest = digest_fields([
        registration.workspace_id.as_str(),
        registration.kind.as_str(),
        registration.managed_agent_id.as_str(),
        now.as_str(),
    ]);
    query(
        "INSERT INTO agent_workspace_members (
            workspace_id, member_id, runtime_kind, managed_agent_kind, managed_agent_id,
            display_name, role, membership_status, liveness_status, runtime_session_id,
            assignment_id, runtime_lifecycle, runtime_evidence, source_session_id,
            source_agent_id, source_digest, membership_source_digest, runtime_source_digest,
            membership_override_source_digest, runtime_override_source_digest,
            joined_at, last_activity_at, created_at, updated_at
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, 'worker', 'joined', 'active', NULL,
            ?7, 'running', ?8, NULL, NULL, ?9, ?9, ?9, NULL, NULL, ?10, ?10, ?10, ?10
         )
         ON CONFLICT(workspace_id, member_id) DO UPDATE SET
            runtime_kind = excluded.runtime_kind,
            display_name = excluded.display_name,
            membership_status = 'joined',
            liveness_status = 'active',
            assignment_id = excluded.assignment_id,
            runtime_lifecycle = 'running',
            runtime_evidence = excluded.runtime_evidence,
            runtime_source_digest = excluded.runtime_source_digest,
            updated_at = excluded.updated_at",
    )
    .bind(&registration.workspace_id)
    .bind(&member_id)
    .bind(&registration.runtime_kind)
    .bind(registration.kind.as_str())
    .bind(&registration.managed_agent_id)
    .bind(&registration.display_name)
    .bind(&registration.assignment_id)
    .bind(&evidence)
    .bind(&source_digest)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("join managed worker to workspace team: {error}")))?;
    // The team's own triggers bump `source_revision` from legacy Session edits.
    // A workspace-owned join has no Session behind it, so the reconciled mark
    // is advanced here; leaving the two apart would read as an unreconciled
    // team and block Session detach for a member that never had a Session.
    query(
        "UPDATE agent_workspace_teams
         SET reconciled_revision = source_revision, updated_at = ?2
         WHERE workspace_id = ?1 AND authority = 'workspace'
           AND selected_legacy_session_id IS NULL",
    )
    .bind(&registration.workspace_id)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("mark workspace team reconciled: {error}")))?;
    Ok(member_id)
}

pub(super) async fn registration_is_current(
    pool: &SqlitePool,
    registration: &WorkspaceMemberRegistration,
) -> Result<bool, CliError> {
    let member_is_current = query_scalar::<_, i64>(
        "SELECT EXISTS (
            SELECT 1 FROM agent_workspace_members
            WHERE workspace_id = ?1 AND member_id = ?2 AND runtime_kind = ?3
              AND managed_agent_kind = ?4 AND managed_agent_id = ?5
              AND display_name = ?6 AND assignment_id IS ?7
              AND membership_status = 'joined' AND liveness_status = 'active'
              AND runtime_lifecycle = 'running'
         )",
    )
    .bind(&registration.workspace_id)
    .bind(registration.member_id())
    .bind(&registration.runtime_kind)
    .bind(registration.kind.as_str())
    .bind(&registration.managed_agent_id)
    .bind(&registration.display_name)
    .bind(&registration.assignment_id)
    .fetch_one(pool)
    .await
    .map_err(|error| {
        db_error(format!(
            "load current workspace member registration: {error}"
        ))
    })? != 0;
    if !member_is_current {
        return Ok(false);
    }
    runtime_owner_is_current(pool, registration).await
}

async fn runtime_owner_is_current(
    pool: &SqlitePool,
    registration: &WorkspaceMemberRegistration,
) -> Result<bool, CliError> {
    let current = match registration.kind {
        super::model::WorkspaceManagedAgentKind::Codex => query_scalar::<_, i64>(
            "SELECT EXISTS (
                SELECT 1 FROM codex_runs
                WHERE run_id = ?1 AND workspace_id = ?2
                  AND session_id IS NULL AND session_agent_id IS NULL
             )",
        ),
        super::model::WorkspaceManagedAgentKind::Terminal => query_scalar::<_, i64>(
            "SELECT EXISTS (
                SELECT 1 FROM agent_tuis
                WHERE tui_id = ?1 AND workspace_id = ?2
                  AND session_id IS NULL AND agent_id = ''
             )",
        ),
        super::model::WorkspaceManagedAgentKind::Acp => query_scalar::<_, i64>(
            "SELECT EXISTS (
                SELECT 1 FROM agent_turn_runs WHERE run_id = ?1 AND session_id = ?2
             )",
        ),
    }
    .bind(&registration.managed_agent_id)
    .bind(&registration.workspace_id)
    .fetch_one(pool)
    .await
    .map_err(|error| db_error(format!("load current managed runtime owner: {error}")))?;
    Ok(current != 0)
}

async fn bind_runtime_owner_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    registration: &WorkspaceMemberRegistration,
) -> Result<(), CliError> {
    let current = match registration.kind {
        super::model::WorkspaceManagedAgentKind::Codex => {
            query_as::<_, (Option<String>,)>(
                "SELECT workspace_id FROM codex_runs WHERE run_id = ?1",
            )
            .bind(&registration.managed_agent_id)
            .fetch_optional(transaction.as_mut())
            .await
        }
        super::model::WorkspaceManagedAgentKind::Terminal => {
            query_as::<_, (Option<String>,)>(
                "SELECT workspace_id FROM agent_tuis WHERE tui_id = ?1",
            )
            .bind(&registration.managed_agent_id)
            .fetch_optional(transaction.as_mut())
            .await
        }
        super::model::WorkspaceManagedAgentKind::Acp => {
            query_as::<_, (Option<String>,)>(
                "SELECT session_id FROM agent_turn_runs WHERE run_id = ?1",
            )
            .bind(&registration.managed_agent_id)
            .fetch_optional(transaction.as_mut())
            .await
        }
    }
    .map_err(|error| db_error(format!("load managed worker workspace owner: {error}")))?;
    let current_owner = current.and_then(|(workspace_id,)| workspace_id);
    let owner_matches = current_owner.as_deref().is_none_or(|workspace_id| {
        workspace_id == registration.workspace_id
            || (registration.kind == super::model::WorkspaceManagedAgentKind::Acp
                && workspace_id == registration.managed_agent_id)
    });
    if !owner_matches {
        return Err(db_error(format!(
            "managed worker '{}' already belongs to another workspace",
            registration.managed_agent_id
        )));
    }
    let result = match registration.kind {
        super::model::WorkspaceManagedAgentKind::Codex => {
            query(
                "UPDATE codex_runs
             SET workspace_id = ?2, session_id = NULL, session_agent_id = NULL
             WHERE run_id = ?1",
            )
            .bind(&registration.managed_agent_id)
            .bind(&registration.workspace_id)
            .execute(transaction.as_mut())
            .await
        }
        super::model::WorkspaceManagedAgentKind::Terminal => {
            query(
                "UPDATE agent_tuis
             SET workspace_id = ?2, session_id = NULL, agent_id = ''
             WHERE tui_id = ?1",
            )
            .bind(&registration.managed_agent_id)
            .bind(&registration.workspace_id)
            .execute(transaction.as_mut())
            .await
        }
        super::model::WorkspaceManagedAgentKind::Acp => {
            query("UPDATE agent_turn_runs SET session_id = ?2 WHERE run_id = ?1")
                .bind(&registration.managed_agent_id)
                .bind(&registration.workspace_id)
                .execute(transaction.as_mut())
                .await
        }
    };
    result
        .map(|_| ())
        .map_err(|error| db_error(format!("bind managed worker to workspace: {error}")))
}

/// Record that a managed worker's runtime stopped, without removing the member.
///
/// Runtime stop and membership removal stay separate results per `#1347`, so
/// compensation lands here and leaves the membership row for history.
pub(super) async fn record_runtime_stop_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    reason: &str,
) -> Result<(), CliError> {
    let now = utc_now();
    query(
        "UPDATE agent_workspace_members
         SET runtime_lifecycle = 'completed',
             runtime_evidence = ?3,
             liveness_status = 'disconnected',
             updated_at = ?4
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(format!("runtime_stop_succeeded;reason={reason}"))
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("record managed worker runtime stop: {error}")))?;
    Ok(())
}
