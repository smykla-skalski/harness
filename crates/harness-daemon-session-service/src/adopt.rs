use harness_kernel::errors::CliError;
use harness_session::adopter::AdoptionOutcome;
use harness_session::index;
use harness_session::service as session_service;

use crate::persistence::build_log_entry;
use crate::ports::{AsyncSignalStorage, SignalStorage};

/// Register an adopted session in the daemon database (sync path).
///
/// # Errors
/// Returns an error on persistence failures.
pub fn adopt_session_record<S: SignalStorage>(
    outcome: &AdoptionOutcome,
    storage: &S,
) -> Result<(), CliError> {
    let canonical_origin = &outcome.state.origin_path;
    harness_session::storage::record_project_origin(canonical_origin)?;
    if let Some(external_origin) = outcome.external_origin.as_deref() {
        harness_session::storage::record_adopted_session_root(
            canonical_origin,
            &outcome.state.session_id,
            external_origin,
        )?;
    }
    let project = index::discovered_project_for_checkout(canonical_origin);
    storage.sync_project(&project)?;
    let project_id = project.project_id;
    storage.create_session_record(&project_id, &outcome.state)?;
    storage.append_log_entry(&build_log_entry(
        &outcome.state.session_id,
        session_service::log_session_adopted(&outcome.state.session_id),
        None,
        None,
    ))?;
    storage.bump_change(&outcome.state.session_id)?;
    storage.bump_change("global")?;
    Ok(())
}

/// Register an adopted session in the daemon database (async path).
///
/// # Errors
/// Returns an error on persistence failures.
pub async fn adopt_session_record_async<A: AsyncSignalStorage>(
    outcome: &AdoptionOutcome,
    storage: &A,
) -> Result<(), CliError> {
    let canonical_origin = &outcome.state.origin_path;
    harness_session::storage::record_project_origin(canonical_origin)?;
    if let Some(external_origin) = outcome.external_origin.as_deref() {
        harness_session::storage::record_adopted_session_root(
            canonical_origin,
            &outcome.state.session_id,
            external_origin,
        )?;
    }
    let project = index::discovered_project_for_checkout(canonical_origin);
    storage.sync_project(&project).await?;
    let project_id = project.project_id;
    storage
        .create_session_record(&project_id, &outcome.state)
        .await?;
    storage
        .append_log_entry(&build_log_entry(
            &outcome.state.session_id,
            session_service::log_session_adopted(&outcome.state.session_id),
            None,
            None,
        ))
        .await?;
    storage.bump_change(&outcome.state.session_id).await?;
    storage.bump_change("global").await?;
    Ok(())
}
