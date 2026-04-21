use crate::errors::CliError;
use crate::session::{service as session_service, storage as session_storage};
use crate::workspace::adopter::AdoptionOutcome;

use super::{build_log_entry, index};

/// Register an adopted session in the daemon `SQLite` DB (sync path).
///
/// # Errors
/// Returns `CliError` on DB failures.
pub fn adopt_session_record(
    outcome: &AdoptionOutcome,
    db: &super::db::DaemonDb,
) -> Result<(), CliError> {
    let canonical_origin = &outcome.state.origin_path;
    session_storage::record_project_origin(canonical_origin)?;
    let project = index::discovered_project_for_checkout(canonical_origin);
    db.sync_project(&project)?;
    let project_id = project.project_id;
    db.create_session_record(&project_id, &outcome.state)?;
    db.append_log_entry(&build_log_entry(
        &outcome.state.session_id,
        session_service::log_session_adopted(&outcome.state.session_id),
        None,
        None,
    ))?;
    db.bump_change(&outcome.state.session_id)?;
    db.bump_change("global")?;
    Ok(())
}

/// Register an adopted session in the daemon `SQLite` DB (async path).
///
/// # Errors
/// Returns `CliError` on DB failures.
pub(crate) async fn adopt_session_record_async(
    outcome: &AdoptionOutcome,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<(), CliError> {
    let canonical_origin = &outcome.state.origin_path;
    session_storage::record_project_origin(canonical_origin)?;
    let project = index::discovered_project_for_checkout(canonical_origin);
    async_db.sync_project(&project).await?;
    let project_id = project.project_id;
    async_db
        .create_session_record(&project_id, &outcome.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            &outcome.state.session_id,
            session_service::log_session_adopted(&outcome.state.session_id),
            None,
            None,
        ))
        .await?;
    async_db.bump_change(&outcome.state.session_id).await?;
    async_db.bump_change("global").await?;
    Ok(())
}
