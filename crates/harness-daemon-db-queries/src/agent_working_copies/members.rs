use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_workspace::workspace::utc_now;
use sqlx::{Sqlite, Transaction, query};

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
