use std::sync::{Arc, Mutex};

use super::super::db;
use super::{CliError, CliErrorKind, SessionStatus, index, state};

/// Startup must not await this. It walks every discovered project, and the
/// manifest that tells the Monitor which port to dial is only written once
/// startup returns, so awaiting it left the daemon undiscoverable for as long
/// as the walk took.
pub(crate) fn spawn_background_reconciliation(db: &Arc<Mutex<db::DaemonDb>>) {
    let db = Arc::clone(db);
    tokio::task::spawn_blocking(move || run_background_reconciliation(&db));
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(crate) fn run_background_reconciliation(db: &Arc<Mutex<db::DaemonDb>>) {
    await_test_gate();
    let (projects, sessions) = match discover_background_reconciliation_inputs() {
        Ok(inputs) => inputs,
        Err(error) => {
            tracing::warn!(%error, "background file reconciliation failed");
            let _ = state::append_event(
                "warn",
                &format!("background file reconciliation failed: {error}"),
            );
            return;
        }
    };

    let mut result = db::ReconcileResult::default();
    let sessions_to_prepare = match sync_background_projects_and_collect_candidates(
        db,
        &projects,
        &sessions,
        &mut result,
    ) {
        Ok(sessions) => sessions,
        Err(error) => {
            tracing::warn!(%error, "background file reconciliation failed");
            let _ = state::append_event(
                "warn",
                &format!("background file reconciliation failed: {error}"),
            );
            return;
        }
    };

    for resolved in &sessions_to_prepare {
        match apply_background_session_import(db, resolved) {
            BackgroundSessionImportOutcome::Imported => result.sessions_imported += 1,
            BackgroundSessionImportOutcome::Skipped => result.sessions_skipped += 1,
            BackgroundSessionImportOutcome::Failed => {}
        }
    }
    let message = format!(
        "background reconciliation: {} projects, {} sessions imported, {} skipped",
        result.projects, result.sessions_imported, result.sessions_skipped
    );
    tracing::info!("{message}");
    let _ = state::append_event("info", &message);
}

pub(crate) fn discover_background_reconciliation_inputs()
-> Result<(Vec<index::DiscoveredProject>, Vec<index::ResolvedSession>), CliError> {
    let projects = index::discover_projects()?;
    let mut sessions = index::discover_sessions_for(&projects, true)?;
    sessions.sort_by(|left, right| {
        let left_active = left.state.status == SessionStatus::Active;
        let right_active = right.state.status == SessionStatus::Active;
        right_active
            .cmp(&left_active)
            .then(right.state.updated_at.cmp(&left.state.updated_at))
            .then(left.state.session_id.cmp(&right.state.session_id))
    });
    Ok((projects, sessions))
}

pub(crate) fn sync_background_projects_and_collect_candidates(
    db: &Arc<Mutex<db::DaemonDb>>,
    projects: &[index::DiscoveredProject],
    sessions: &[index::ResolvedSession],
    result: &mut db::ReconcileResult,
) -> Result<Vec<index::ResolvedSession>, CliError> {
    sync_background_projects(db, projects, result)?;
    Ok(collect_background_session_candidates(db, sessions, result))
}

enum BackgroundSessionImportOutcome {
    Failed,
    Imported,
    Skipped,
}

enum BackgroundSessionCandidate {
    Failed,
    Prepare,
    Skip,
}

fn apply_background_session_import(
    db: &Arc<Mutex<db::DaemonDb>>,
    resolved: &index::ResolvedSession,
) -> BackgroundSessionImportOutcome {
    let Some(prepared) = prepare_background_session_import(resolved) else {
        return BackgroundSessionImportOutcome::Failed;
    };
    let Ok(db_guard) = db.lock() else {
        return BackgroundSessionImportOutcome::Failed;
    };
    apply_prepared_background_session_import(&db_guard, &prepared)
}

/// Takes the lock per project rather than once for the whole walk. This work
/// now overlaps a serving daemon, and request handlers contend for the same
/// mutex, so one long hold would stall them for the length of the walk.
pub(crate) fn sync_background_projects(
    db: &Arc<Mutex<db::DaemonDb>>,
    projects: &[index::DiscoveredProject],
    result: &mut db::ReconcileResult,
) -> Result<(), CliError> {
    for project in projects {
        let Ok(db_guard) = db.lock() else {
            return Ok(());
        };
        let synced = db_guard.sync_project(project).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "sync project {}: {error}",
                project.project_id
            )))
        });
        drop(db_guard);
        synced?;
        result.projects += 1;
    }
    Ok(())
}

pub(crate) fn collect_background_session_candidates(
    db: &Arc<Mutex<db::DaemonDb>>,
    sessions: &[index::ResolvedSession],
    result: &mut db::ReconcileResult,
) -> Vec<index::ResolvedSession> {
    let mut sessions_to_prepare = Vec::new();
    for resolved in sessions {
        let Ok(db_guard) = db.lock() else {
            break;
        };
        let candidate = background_session_candidate(&db_guard, resolved);
        drop(db_guard);
        match candidate {
            BackgroundSessionCandidate::Prepare => sessions_to_prepare.push(resolved.clone()),
            BackgroundSessionCandidate::Skip | BackgroundSessionCandidate::Failed => {
                result.sessions_skipped += 1;
            }
        }
    }
    sessions_to_prepare
}

pub(crate) fn prepare_background_session_import(
    resolved: &index::ResolvedSession,
) -> Option<db::PreparedSessionResync> {
    db::DaemonDb::prepare_session_import_from_resolved(resolved)
        .inspect_err(|error| log_background_session_prepare_error(error, resolved))
        .ok()
}

fn apply_prepared_background_session_import(
    db: &db::DaemonDb,
    prepared: &db::PreparedSessionResync,
) -> BackgroundSessionImportOutcome {
    let Some(import_required) = prepared_session_import_required(db, prepared) else {
        return BackgroundSessionImportOutcome::Failed;
    };
    if !import_required {
        return BackgroundSessionImportOutcome::Skipped;
    }
    import_prepared_background_session(db, prepared)
}

pub(crate) fn session_import_required(
    db: &db::DaemonDb,
    resolved: &index::ResolvedSession,
) -> Result<bool, CliError> {
    let db_version = db.session_state_version(&resolved.state.session_id)?;
    let file_version = i64::try_from(resolved.state.state_version).unwrap_or(i64::MAX);
    Ok(db_version.is_none_or(|version| version < file_version))
}

fn background_session_candidate(
    db: &db::DaemonDb,
    resolved: &index::ResolvedSession,
) -> BackgroundSessionCandidate {
    match session_import_required(db, resolved) {
        Ok(false) => BackgroundSessionCandidate::Skip,
        Ok(true) => BackgroundSessionCandidate::Prepare,
        Err(error) => {
            log_background_session_version_check_error(&error, resolved);
            BackgroundSessionCandidate::Failed
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn log_background_session_prepare_error(
    error: &CliError,
    resolved: &index::ResolvedSession,
) {
    tracing::warn!(
        %error,
        session_id = %resolved.state.session_id,
        "background session prepare failed"
    );
}

pub(crate) fn prepared_session_import_required(
    db: &db::DaemonDb,
    prepared: &db::PreparedSessionResync,
) -> Option<bool> {
    session_import_required(db, &prepared.resolved)
        .inspect_err(|error| log_background_session_version_check_error(error, &prepared.resolved))
        .ok()
}

fn import_prepared_background_session(
    db: &db::DaemonDb,
    prepared: &db::PreparedSessionResync,
) -> BackgroundSessionImportOutcome {
    if let Err(error) = db.apply_prepared_session_resync(prepared) {
        log_background_session_import_error(&error, prepared);
        return BackgroundSessionImportOutcome::Failed;
    }
    BackgroundSessionImportOutcome::Imported
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn log_background_session_version_check_error(
    error: &CliError,
    resolved: &index::ResolvedSession,
) {
    tracing::warn!(
        %error,
        session_id = %resolved.state.session_id,
        "background session version check failed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(crate) fn log_background_session_import_error(
    error: &CliError,
    prepared: &db::PreparedSessionResync,
) {
    tracing::warn!(
        %error,
        session_id = %prepared.resolved.state.session_id,
        "background session import failed"
    );
}

#[cfg(not(test))]
const fn await_test_gate() {}

#[cfg(test)]
fn await_test_gate() {
    test_gate::wait();
}

#[cfg(test)]
pub(crate) mod test_gate {
    use std::sync::{Arc, Condvar, Mutex};

    pub(crate) type Gate = Arc<(Mutex<bool>, Condvar)>;

    static INSTALLED: Mutex<Option<Gate>> = Mutex::new(None);

    /// Hold reconciliation at its entry point so a test can prove the daemon
    /// publishes its manifest without waiting for it.
    pub(crate) fn install() -> Gate {
        let gate: Gate = Arc::new((Mutex::new(false), Condvar::new()));
        *INSTALLED.lock().expect("reconciliation gate") = Some(Arc::clone(&gate));
        gate
    }

    pub(crate) fn release(gate: &Gate) {
        let (flag, condvar) = &**gate;
        *flag.lock().expect("reconciliation gate flag") = true;
        condvar.notify_all();
    }

    pub(crate) fn clear() {
        *INSTALLED.lock().expect("reconciliation gate") = None;
    }

    pub(super) fn wait() {
        let installed = INSTALLED
            .lock()
            .ok()
            .and_then(|guard| guard.as_ref().map(Arc::clone));
        let Some(gate) = installed else {
            return;
        };
        let (flag, condvar) = &*gate;
        let mut released = flag.lock().expect("reconciliation gate flag");
        while !*released {
            released = condvar.wait(released).expect("reconciliation gate wait");
        }
    }
}
