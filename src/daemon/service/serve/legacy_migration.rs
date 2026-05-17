use crate::daemon::state;

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(super) fn log_legacy_daemon_root_migration(report: &state::LegacyDaemonRootMigration) {
    use state::MigrationDecision;

    match &report.decision {
        MigrationDecision::Migrated { count } => {
            tracing::info!(
                from = %report.from.display(),
                to = %report.to.display(),
                entries = count,
                "migrated legacy daemon state into ownership-scoped subtree"
            );
            let _ = state::append_event(
                "info",
                &format!(
                    "migrated {} legacy daemon entries from {} into {}",
                    count,
                    report.from.display(),
                    report.to.display(),
                ),
            );
        }
        MigrationDecision::OwnershipMismatch { inferred, current } => {
            tracing::info!(
                from = %report.from.display(),
                inferred = %inferred,
                current = %current,
                "legacy daemon state belongs to other ownership; leaving for sibling daemon to migrate"
            );
        }
        MigrationDecision::LegacyDaemonAlive => {
            tracing::warn!(
                from = %report.from.display(),
                "legacy daemon still running; skipping migration"
            );
        }
        MigrationDecision::UnreadableLegacyManifest => {
            tracing::warn!(
                from = %report.from.display(),
                "legacy daemon manifest is unreadable; skipping migration"
            );
        }
        MigrationDecision::AlreadyMigrated | MigrationDecision::NoLegacyState => {}
    }
}
