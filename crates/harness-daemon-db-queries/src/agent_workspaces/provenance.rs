use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use sqlx::{Sqlite, Transaction, query};

use super::persist::availability_label;
use super::preflight::WorkspacePlan;

pub(super) async fn persist_workspace_provenance(
    transaction: &mut Transaction<'_, Sqlite>,
    plan: &WorkspacePlan,
) -> Result<(), CliError> {
    let current_session_ids = serde_json::to_string(
        &plan
            .candidates
            .iter()
            .map(|candidate| candidate.session_id.as_str())
            .collect::<Vec<_>>(),
    )
    .map_err(|error| db_error(format!("serialize workspace provenance ids: {error}")))?;
    query(
        "DELETE FROM agent_workspace_legacy_sessions
         WHERE workspace_id = ?1
           AND session_id NOT IN (SELECT value FROM json_each(?2))",
    )
    .bind(&plan.workspace_id)
    .bind(current_session_ids)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("retire workspace provenance: {error}")))?;
    clear_previous_selection(transaction, plan).await?;
    for candidate in &plan.candidates {
        query(
            "INSERT INTO agent_workspace_legacy_sessions (
                workspace_id, session_id, lifecycle, checkout_availability,
                liveness_evidence, effective_activity_at, session_updated_at,
                session_created_at, source_digest, is_selected
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(workspace_id, session_id) DO UPDATE SET
                lifecycle = excluded.lifecycle,
                checkout_availability = excluded.checkout_availability,
                liveness_evidence = excluded.liveness_evidence,
                effective_activity_at = excluded.effective_activity_at,
                session_updated_at = excluded.session_updated_at,
                session_created_at = excluded.session_created_at,
                source_digest = excluded.source_digest,
                is_selected = excluded.is_selected
             WHERE lifecycle IS NOT excluded.lifecycle
                OR checkout_availability IS NOT excluded.checkout_availability
                OR liveness_evidence IS NOT excluded.liveness_evidence
                OR effective_activity_at IS NOT excluded.effective_activity_at
                OR session_updated_at IS NOT excluded.session_updated_at
                OR session_created_at IS NOT excluded.session_created_at
                OR source_digest IS NOT excluded.source_digest
                OR is_selected IS NOT excluded.is_selected",
        )
        .bind(&plan.workspace_id)
        .bind(&candidate.session_id)
        .bind(candidate.lifecycle.as_str())
        .bind(availability_label(candidate.availability))
        .bind(&candidate.liveness_evidence)
        .bind(&candidate.effective_activity_at)
        .bind(&candidate.updated_at)
        .bind(&candidate.created_at)
        .bind(&candidate.source_digest)
        .bind(candidate.session_id == plan.selected_session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("persist workspace Session provenance: {error}")))?;
    }
    Ok(())
}

async fn clear_previous_selection(
    transaction: &mut Transaction<'_, Sqlite>,
    plan: &WorkspacePlan,
) -> Result<(), CliError> {
    query(
        "UPDATE agent_workspace_legacy_sessions
         SET is_selected = 0
         WHERE workspace_id = ?1 AND is_selected = 1 AND session_id <> ?2",
    )
    .bind(&plan.workspace_id)
    .bind(&plan.selected_session_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("transfer workspace provenance selection: {error}")))?;
    Ok(())
}
