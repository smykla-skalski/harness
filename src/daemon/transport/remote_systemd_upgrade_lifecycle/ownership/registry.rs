use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

use super::super::super::remote_systemd_lifecycle::validate_canonical_unit_name;
use super::super::files::io_error;
use super::path::{BinaryOwnershipKey, current_binary_file_identity, normalize_absolute_utf8};

const REGISTRY_VERSION: u32 = 1;
const CLAIM_VERSION: u32 = 1;

#[path = "registry/storage.rs"]
mod storage;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::daemon::transport) struct BinaryClaim {
    claim_version: u32,
    unit: String,
    binary_path: PathBuf,
    resolved_binary_path: PathBuf,
    parent_device: u64,
    parent_inode: u64,
    entry_name: String,
}

impl BinaryClaim {
    pub(in crate::daemon::transport) fn unit(&self) -> &str {
        &self.unit
    }

    pub(in crate::daemon::transport) fn binary_path(&self) -> &Path {
        &self.binary_path
    }

    pub(super) fn resolved_binary_path(&self) -> &Path {
        &self.resolved_binary_path
    }

    pub(super) fn matches_key(&self, key: &BinaryOwnershipKey) -> bool {
        self.resolved_binary_path == key.resolved_path
            && self.parent_device == key.parent.device
            && self.parent_inode == key.parent.inode
            && self.entry_name == key.entry_name
    }

    fn shares_entry(&self, key: &BinaryOwnershipKey) -> bool {
        self.parent_device == key.parent.device
            && self.parent_inode == key.parent.inode
            && self.entry_name == key.entry_name
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegistryDocument {
    registry_version: u32,
    claims: Vec<ClaimRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimRecord {
    claim_version: u32,
    unit: String,
    binary_path: String,
    resolved_binary_path: String,
    parent_device: u64,
    parent_inode: u64,
    entry_name: String,
}

#[derive(Debug)]
pub(super) struct ClaimRegistry {
    document: RegistryDocument,
}

impl ClaimRegistry {
    pub(super) fn load(transaction_root: &Path) -> Result<Self, CliError> {
        let registry = storage::load_document(transaction_root)?
            .map_or_else(Self::empty, |document| Self { document });
        registry.validate()?;
        registry.validate_namespace(transaction_root)?;
        Ok(registry)
    }

    pub(super) fn claim_for_unit(&self, unit: &str) -> Option<BinaryClaim> {
        self.document
            .claims
            .iter()
            .find(|claim| claim.unit == unit)
            .map(ClaimRecord::to_claim)
    }

    pub(super) fn bind(
        &mut self,
        unit: &str,
        binary_path: &Path,
        key: &BinaryOwnershipKey,
        allow_adoption: bool,
    ) -> Result<(BinaryClaim, bool), CliError> {
        if let Some(existing) = self.claim_for_unit(unit) {
            if existing.binary_path() == binary_path && existing.matches_key(key) {
                return Ok((existing, false));
            }
            return Err(registry_error(format!(
                "systemd unit {unit} already claims binary {} at resolved path {}, refusing {} at resolved path {}",
                existing.binary_path().display(),
                existing.resolved_binary_path().display(),
                binary_path.display(),
                key.resolved_path.display()
            )));
        }
        if let Some(existing) = self.claim_for_binary(binary_path, key)? {
            return Err(registry_error(format!(
                "systemd binary {} resolves to an ownership target already claimed by unit {}",
                binary_path.display(),
                existing.unit()
            )));
        }
        if !allow_adoption {
            return Err(registry_error(format!(
                "systemd unit {unit} has no existing binary ownership claim"
            )));
        }
        let claim = BinaryClaim {
            claim_version: CLAIM_VERSION,
            unit: unit.to_string(),
            binary_path: binary_path.to_path_buf(),
            resolved_binary_path: key.resolved_path.clone(),
            parent_device: key.parent.device,
            parent_inode: key.parent.inode,
            entry_name: key.entry_name.clone(),
        };
        self.document.claims.push(ClaimRecord::from_claim(&claim)?);
        self.document
            .claims
            .sort_unstable_by(|left, right| left.unit.cmp(&right.unit));
        self.validate()?;
        Ok((claim, true))
    }

    pub(super) fn remove_exact(&mut self, expected: &BinaryClaim) -> Result<(), CliError> {
        let Some(index) = self
            .document
            .claims
            .iter()
            .position(|claim| claim.unit == expected.unit)
        else {
            return Err(registry_error(format!(
                "binary ownership claim disappeared for systemd unit {}",
                expected.unit
            )));
        };
        let observed = self.document.claims[index].to_claim();
        if observed != *expected {
            return Err(registry_error(format!(
                "binary ownership claim changed for systemd unit {}",
                expected.unit
            )));
        }
        self.document.claims.remove(index);
        self.validate()
    }

    pub(super) fn persist(&self, transaction_root: &Path) -> Result<(), CliError> {
        self.validate()?;
        self.validate_namespace(transaction_root)?;
        storage::persist_document(transaction_root, &self.document)
    }

    fn empty() -> Self {
        Self {
            document: RegistryDocument {
                registry_version: REGISTRY_VERSION,
                claims: Vec::new(),
            },
        }
    }

    pub(super) fn reject_claim_conflict(
        &self,
        unit: &str,
        binary_path: &Path,
        key: &BinaryOwnershipKey,
    ) -> Result<(), CliError> {
        if self.claim_for_unit(unit).is_some() {
            return Err(registry_error(format!(
                "systemd unit {unit} already has a binary ownership claim"
            )));
        }
        if let Some(existing) = self.claim_for_binary(binary_path, key)? {
            return Err(registry_error(format!(
                "legacy systemd binary {} conflicts with the ownership claim for unit {}",
                binary_path.display(),
                existing.unit()
            )));
        }
        Ok(())
    }

    fn claim_for_binary(
        &self,
        binary_path: &Path,
        key: &BinaryOwnershipKey,
    ) -> Result<Option<BinaryClaim>, CliError> {
        for claim in self.document.claims.iter().map(ClaimRecord::to_claim) {
            if claim.binary_path() == binary_path || claim.shares_entry(key) {
                return Ok(Some(claim));
            }
            if current_binary_file_identity(claim.binary_path())? == Some(key.current_file) {
                return Ok(Some(claim));
            }
        }
        Ok(None)
    }

    fn validate(&self) -> Result<(), CliError> {
        if self.document.registry_version != REGISTRY_VERSION {
            return Err(registry_error(format!(
                "unsupported binary claim registry version {}",
                self.document.registry_version
            )));
        }
        for claim in &self.document.claims {
            claim.validate()?;
        }
        validate_sorted_units(&self.document.claims)?;
        validate_unique_binary_paths(&self.document.claims)?;
        validate_unique_resolved_paths(&self.document.claims)?;
        validate_unique_entries(&self.document.claims)
    }

    fn validate_namespace(&self, transaction_root: &Path) -> Result<(), CliError> {
        for claim in &self.document.claims {
            validate_claim_outside_transaction_root(claim, transaction_root)?;
        }
        Ok(())
    }
}

fn validate_claim_outside_transaction_root(
    claim: &ClaimRecord,
    transaction_root: &Path,
) -> Result<(), CliError> {
    for (label, path) in [
        ("binary", claim.binary_path.as_str()),
        ("resolved binary", claim.resolved_binary_path.as_str()),
    ] {
        if Path::new(path).starts_with(transaction_root) {
            return Err(registry_error(format!(
                "systemd {label} ownership claim overlaps transaction root {}: {path}",
                transaction_root.display()
            )));
        }
    }
    Ok(())
}

fn validate_sorted_units(claims: &[ClaimRecord]) -> Result<(), CliError> {
    for (left, right) in claims.iter().zip(claims.iter().skip(1)) {
        validate_unit_order(left, right)?;
    }
    Ok(())
}

fn validate_unit_order(left: &ClaimRecord, right: &ClaimRecord) -> Result<(), CliError> {
    match left.unit.cmp(&right.unit) {
        Ordering::Less => Ok(()),
        Ordering::Equal => Err(registry_error(format!(
            "duplicate binary claim for systemd unit {}",
            left.unit
        ))),
        Ordering::Greater => Err(registry_error(
            "binary claim registry entries are not sorted by unit",
        )),
    }
}

fn validate_unique_binary_paths(claims: &[ClaimRecord]) -> Result<(), CliError> {
    let mut binary_paths = BTreeSet::new();
    for claim in claims {
        if !binary_paths.insert(claim.binary_path.as_str()) {
            return Err(registry_error(format!(
                "duplicate systemd binary ownership claim for {}",
                claim.binary_path
            )));
        }
    }
    Ok(())
}

fn validate_unique_resolved_paths(claims: &[ClaimRecord]) -> Result<(), CliError> {
    let mut resolved_paths = BTreeSet::new();
    for claim in claims {
        if !resolved_paths.insert(claim.resolved_binary_path.as_str()) {
            return Err(registry_error(format!(
                "duplicate resolved systemd binary ownership claim for {}",
                claim.resolved_binary_path
            )));
        }
    }
    Ok(())
}

fn validate_unique_entries(claims: &[ClaimRecord]) -> Result<(), CliError> {
    let mut entries = BTreeSet::new();
    for claim in claims {
        let entry = (
            claim.parent_device,
            claim.parent_inode,
            claim.entry_name.as_str(),
        );
        if !entries.insert(entry) {
            return Err(registry_error(format!(
                "duplicate systemd binary ownership entry {} on directory {}:{}",
                claim.entry_name, claim.parent_device, claim.parent_inode
            )));
        }
    }
    Ok(())
}

impl ClaimRecord {
    fn from_claim(claim: &BinaryClaim) -> Result<Self, CliError> {
        let binary_path = claim.binary_path.to_str().ok_or_else(|| {
            registry_error(format!(
                "binary ownership claim path is not UTF-8: {}",
                claim.binary_path.display()
            ))
        })?;
        let resolved_binary_path = claim.resolved_binary_path.to_str().ok_or_else(|| {
            registry_error(format!(
                "resolved binary ownership claim path is not UTF-8: {}",
                claim.resolved_binary_path.display()
            ))
        })?;
        Ok(Self {
            claim_version: claim.claim_version,
            unit: claim.unit.clone(),
            binary_path: binary_path.to_string(),
            resolved_binary_path: resolved_binary_path.to_string(),
            parent_device: claim.parent_device,
            parent_inode: claim.parent_inode,
            entry_name: claim.entry_name.clone(),
        })
    }

    fn to_claim(&self) -> BinaryClaim {
        BinaryClaim {
            claim_version: self.claim_version,
            unit: self.unit.clone(),
            binary_path: PathBuf::from(&self.binary_path),
            resolved_binary_path: PathBuf::from(&self.resolved_binary_path),
            parent_device: self.parent_device,
            parent_inode: self.parent_inode,
            entry_name: self.entry_name.clone(),
        }
    }

    fn validate(&self) -> Result<(), CliError> {
        if self.claim_version != CLAIM_VERSION {
            return Err(registry_error(format!(
                "unsupported binary ownership claim version {} for unit {}",
                self.claim_version, self.unit
            )));
        }
        validate_canonical_unit_name(&self.unit)?;
        normalize_absolute_utf8(
            "systemd binary ownership claim",
            Path::new(&self.binary_path),
        )?;
        normalize_absolute_utf8(
            "resolved systemd binary ownership claim",
            Path::new(&self.resolved_binary_path),
        )?;
        validate_entry_name(&self.resolved_binary_path, &self.entry_name)?;
        Ok(())
    }
}

fn validate_entry_name(resolved_path: &str, entry_name: &str) -> Result<(), CliError> {
    let expected = Path::new(resolved_path)
        .file_name()
        .and_then(|name| name.to_str());
    if expected == Some(entry_name) {
        Ok(())
    } else {
        Err(registry_error(format!(
            "resolved systemd binary ownership filename mismatch: path {resolved_path}, entry {entry_name:?}"
        )))
    }
}

fn registry_error(message: impl Into<String>) -> CliError {
    io_error(message)
}
