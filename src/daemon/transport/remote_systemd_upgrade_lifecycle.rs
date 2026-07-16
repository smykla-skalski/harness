mod automation;
mod binary;
mod capacity;
mod database;
mod files;
mod generation;
mod generation_restore;
mod integrity;
mod model;
mod ownership;
mod recovery;
mod recovery_cleanup;
mod rollback;
mod state;
mod systemd;
mod systemd_reset;
mod target_database;
mod unit_contract;
mod upgrade_failure;
mod workflow;

#[allow(unused_imports, reason = "preserve the lifecycle facade API")]
pub(crate) use model::{
    RemoteSystemdArtifact, RemoteSystemdHealthReport, RemoteSystemdRecoveryOutcome,
    RemoteSystemdUpgradeOutcome,
};
pub(crate) use model::{
    RemoteSystemdOperationPlan, RemoteSystemdRecoveryReport, RemoteSystemdRollbackReport,
    RemoteSystemdUpgradePlan, RemoteSystemdUpgradeReport,
};
pub(in crate::daemon::transport) use ownership::{BindMode, LockedLifecycle};
pub(in crate::daemon::transport) use recovery::ensure_systemd_lifecycle_unarmed;
pub(crate) use recovery::recover_remote_systemd_with;
pub(crate) use recovery_cleanup::cleanup_recovery_artifacts;
pub(crate) use rollback::rollback_remote_systemd_with;
pub(crate) use systemd::verify_remote_systemd_health;
pub(crate) use workflow::upgrade_remote_systemd_with;

#[cfg(test)]
pub(crate) use automation::render_recovery_units_for_tests;
#[cfg(test)]
pub(crate) fn acquire_with_trusted_controller<Lock, Acquire>(
    plan: &RemoteSystemdOperationPlan,
    acquire: Acquire,
) -> Result<Lock, crate::errors::CliError>
where
    Acquire: FnOnce() -> Result<Lock, crate::errors::CliError>,
{
    binary::acquire_with_trusted_controller(plan, acquire)
}
#[cfg(test)]
pub(crate) use capacity::{
    reconcile_restore_debris_for_tests, release_restore_capacity_for_tests,
    required_restore_capacity_for_tests, required_restore_inodes_for_tests,
    reserve_bidirectional_restore_capacity_for_tests,
    reserve_inode_capacity_with_available_for_tests,
};
#[cfg(test)]
pub(crate) use files::atomic_copy_temp_prefix_for_tests;
#[cfg(test)]
pub(crate) use generation::{reconcile_rotation_state_for_tests, snapshot_generation_for_tests};
#[cfg(test)]
pub(crate) use state::{
    restore_state_tree_for_tests, restore_state_tree_retaining_current_for_tests,
    snapshot_state_tree_for_tests,
};
#[cfg(test)]
pub(crate) use systemd::{
    notify_unit_contents_for_tests, parse_systemd_observation_for_tests,
    restart_stability_behavior_for_tests, stability_reset_sequence_for_tests,
};
