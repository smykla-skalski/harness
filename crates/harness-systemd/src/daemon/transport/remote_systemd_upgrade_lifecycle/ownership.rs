use std::path::{Path, PathBuf};

use crate::errors::CliError;

use super::super::binary_exclusivity::validate_exclusive_systemd_binary;
use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::files::{create_private_directory, io_error, validate_private_directory};
use super::model::OPERATION_LOCK_FILE;
use super::recovery::ensure_systemd_lifecycle_unarmed;
use super::release_pair;

#[path = "ownership/locks.rs"]
mod locks;
#[path = "ownership/path.rs"]
mod path;
#[path = "ownership/registry.rs"]
mod registry;

use locks::{StrictFlockGuard, try_acquire_strict_lock};
use path::{
    BinaryOwnershipKey, LifecyclePaths, normalize_absolute_utf8, resolve_binary_ownership_key,
};
pub(in crate::daemon::transport) use registry::BinaryClaim;
use registry::ClaimRegistry;

const GLOBAL_LOCK_FILE: &str = ".lifecycle.lock";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::daemon::transport) enum BindMode {
    InstallOrMatch,
    LegacyOperationOrMatch,
    ExistingOnly,
}

impl BindMode {
    const fn allows_adoption(self) -> bool {
        matches!(self, Self::InstallOrMatch | Self::LegacyOperationOrMatch)
    }
}

#[derive(Debug)]
pub(in crate::daemon::transport) struct LockedLifecycle {
    transaction_root: PathBuf,
    store_path: PathBuf,
    unit: String,
    unit_guard: Option<StrictFlockGuard>,
    global_guard: Option<StrictFlockGuard>,
}

impl LockedLifecycle {
    pub(in crate::daemon::transport) fn acquire(
        transaction_root: &Path,
        unit: &str,
        store_path: &Path,
    ) -> Result<Self, CliError> {
        Self::try_acquire(transaction_root, unit, store_path)?.ok_or_else(|| {
            io_error(format!(
                "another remote systemd lifecycle operation is already running for {unit}"
            ))
        })
    }

    pub(in crate::daemon::transport) fn try_acquire(
        transaction_root: &Path,
        unit: &str,
        store_path: &Path,
    ) -> Result<Option<Self>, CliError> {
        let paths = LifecyclePaths::validate(transaction_root, unit, store_path)?;
        create_private_directory(&paths.transaction_root)?;
        let Some(global_guard) =
            try_acquire_strict_lock(&paths.transaction_root.join(GLOBAL_LOCK_FILE))?
        else {
            return Ok(None);
        };
        create_private_directory(&paths.store_path)?;
        let Some(unit_guard) =
            try_acquire_strict_lock(&paths.store_path.join(OPERATION_LOCK_FILE))?
        else {
            drop(global_guard);
            return Ok(None);
        };
        Ok(Some(Self {
            transaction_root: paths.transaction_root,
            store_path: paths.store_path,
            unit: unit.to_string(),
            unit_guard: Some(unit_guard),
            global_guard: Some(global_guard),
        }))
    }

    #[cfg(test)]
    pub(super) fn unit(&self) -> &str {
        &self.unit
    }

    #[cfg(test)]
    pub(super) fn store_path(&self) -> &Path {
        &self.store_path
    }

    pub(in crate::daemon::transport) fn claim_for_unit(
        &self,
    ) -> Result<Option<BinaryClaim>, CliError> {
        self.validate_locked_directories()?;
        Ok(ClaimRegistry::load(&self.transaction_root)?.claim_for_unit(&self.unit))
    }

    pub(in crate::daemon::transport) fn validate_legacy_uninstall_binary<RunSystemctl>(
        &self,
        binary_path: &Path,
        run_systemctl: &RunSystemctl,
    ) -> Result<(), CliError>
    where
        RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    {
        self.validate_locked_directories()?;
        let binary_path = normalize_absolute_utf8("legacy systemd binary", binary_path)?;
        self.validate_binary_namespace("legacy systemd binary", &binary_path)?;
        validate_exclusive_systemd_binary(&self.unit, &binary_path, run_systemctl)?;
        let key = resolve_binary_ownership_key(&binary_path)?;
        self.validate_binary_namespace("resolved legacy systemd binary", &key.resolved_path)?;
        ClaimRegistry::load(&self.transaction_root)?.reject_claim_conflict(
            &self.unit,
            &binary_path,
            &key,
        )
    }

    pub(in crate::daemon::transport) fn bind<RunSystemctl>(
        self,
        binary_path: &Path,
        mode: BindMode,
        run_systemctl: &RunSystemctl,
    ) -> Result<ClaimedLifecycle, CliError>
    where
        RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    {
        self.validate_locked_directories()?;
        let binary_path = normalize_absolute_utf8("systemd claimed binary", binary_path)?;
        self.validate_binary_namespace("systemd claimed binary", &binary_path)?;
        validate_exclusive_systemd_binary(&self.unit, &binary_path, run_systemctl)?;
        let key = resolve_binary_ownership_key(&binary_path)?;
        self.validate_binary_namespace("resolved systemd claimed binary", &key.resolved_path)?;
        let mut registry = ClaimRegistry::load(&self.transaction_root)?;
        let (claim, changed) =
            registry.bind(&self.unit, &binary_path, &key, mode.allows_adoption())?;
        Ok(ClaimedLifecycle {
            locked: self,
            claim,
            persisted: !changed,
        })
    }

    fn validate_locked_directories(&self) -> Result<(), CliError> {
        validate_private_directory(&self.transaction_root)?;
        validate_private_directory(&self.store_path)
    }

    fn validate_binary_namespace(&self, label: &str, path: &Path) -> Result<(), CliError> {
        if path.starts_with(&self.transaction_root) {
            Err(io_error(format!(
                "{label} overlaps remote systemd transaction root {}: {}",
                self.transaction_root.display(),
                path.display()
            )))
        } else {
            Ok(())
        }
    }
}

impl Drop for LockedLifecycle {
    fn drop(&mut self) {
        drop(self.unit_guard.take());
        drop(self.global_guard.take());
    }
}

#[derive(Debug)]
pub(in crate::daemon::transport) struct ClaimedLifecycle {
    locked: LockedLifecycle,
    claim: BinaryClaim,
    persisted: bool,
}

impl ClaimedLifecycle {
    #[cfg(test)]
    pub(super) fn claim(&self) -> &BinaryClaim {
        &self.claim
    }

    pub(in crate::daemon::transport) const fn claim_is_persisted(&self) -> bool {
        self.persisted
    }

    pub(in crate::daemon::transport) fn persist_claim<RunSystemctl>(
        &mut self,
        run_systemctl: &RunSystemctl,
    ) -> Result<(), CliError>
    where
        RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    {
        if self.persisted {
            return self.recheck(run_systemctl);
        }
        let key = self.validate_live_claim(run_systemctl)?;
        let mut registry = ClaimRegistry::load(&self.locked.transaction_root)?;
        let unit = self.claim.unit();
        let binary_path = self.claim.binary_path();
        let (claim, changed) = registry.bind(unit, binary_path, &key, true)?;
        if claim != self.claim {
            return Err(io_error(format!(
                "binary ownership claim changed before persistence for systemd unit {}",
                self.claim.unit()
            )));
        }
        if changed {
            registry.persist(&self.locked.transaction_root)?;
        }
        self.persisted = true;
        Ok(())
    }

    pub(in crate::daemon::transport) fn recheck<RunSystemctl>(
        &self,
        run_systemctl: &RunSystemctl,
    ) -> Result<(), CliError>
    where
        RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    {
        if !self.persisted {
            return Err(io_error(format!(
                "binary ownership claim is not yet durable for systemd unit {}",
                self.claim.unit()
            )));
        }
        self.locked.validate_locked_directories()?;
        let registry = ClaimRegistry::load(&self.locked.transaction_root)?;
        let current = registry.claim_for_unit(self.claim.unit()).ok_or_else(|| {
            io_error(format!(
                "binary ownership claim disappeared for systemd unit {}",
                self.claim.unit()
            ))
        })?;
        if current != self.claim {
            return Err(io_error(format!(
                "binary ownership claim changed for systemd unit {}",
                self.claim.unit()
            )));
        }
        self.validate_live_claim(run_systemctl)?;
        Ok(())
    }

    pub(in crate::daemon::transport) fn establish_release_pair<RunSystemctl>(
        &self,
        controller_path: &Path,
        run_systemctl: &RunSystemctl,
    ) -> Result<(), CliError>
    where
        RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    {
        self.recheck(run_systemctl)?;
        ensure_systemd_lifecycle_unarmed(&self.locked.store_path)?;
        release_pair::establish_locked_release_pair(
            self.claim.unit(),
            self.claim.binary_path(),
            controller_path,
            &self.locked.store_path,
        )
    }

    fn validate_live_claim<RunSystemctl>(
        &self,
        run_systemctl: &RunSystemctl,
    ) -> Result<BinaryOwnershipKey, CliError>
    where
        RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    {
        self.locked.validate_locked_directories()?;
        validate_exclusive_systemd_binary(
            self.claim.unit(),
            self.claim.binary_path(),
            run_systemctl,
        )?;
        let key = resolve_binary_ownership_key(self.claim.binary_path())?;
        self.locked
            .validate_binary_namespace("resolved systemd claimed binary", &key.resolved_path)?;
        if self.claim.matches_key(&key) {
            Ok(key)
        } else {
            Err(io_error(format!(
                "systemd binary ownership target changed for unit {}: expected {}, found {}",
                self.claim.unit(),
                self.claim.resolved_binary_path().display(),
                key.resolved_path.display()
            )))
        }
    }

    pub(in crate::daemon::transport) fn remove_claim(self) -> Result<LockedLifecycle, CliError> {
        if !self.persisted {
            return Err(io_error(format!(
                "cannot remove provisional binary ownership claim for systemd unit {}",
                self.claim.unit()
            )));
        }
        let Self {
            locked,
            claim,
            persisted: _,
        } = self;
        locked.validate_locked_directories()?;
        let mut registry = ClaimRegistry::load(&locked.transaction_root)?;
        registry.remove_exact(&claim)?;
        registry.persist(&locked.transaction_root)?;
        Ok(locked)
    }
}

#[cfg(test)]
#[path = "ownership/tests.rs"]
mod tests;
