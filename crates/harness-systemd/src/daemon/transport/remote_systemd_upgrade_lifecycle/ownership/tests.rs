use std::cell::Cell;
use std::fs::{self, Permissions};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use tempfile::{TempDir, tempdir};

use crate::daemon::transport::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use crate::errors::CliError;

use super::super::model::OPERATION_LOCK_FILE;
use super::locks::try_acquire_strict_lock;
use super::{BindMode, GLOBAL_LOCK_FILE, LockedLifecycle, create_private_directory};

#[path = "tests/aliases.rs"]
mod aliases;
#[path = "tests/removal.rs"]
mod removal;

struct Fixture {
    _temporary: TempDir,
    root: PathBuf,
    binary: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let temporary = tempdir().expect("temporary directory");
        let root = temporary.path().join("transactions");
        let binary = temporary.path().join("harness");
        fs::write(&binary, b"harness").expect("binary");
        fs::set_permissions(&binary, Permissions::from_mode(0o700)).expect("binary mode");
        Self {
            _temporary: temporary,
            root,
            binary,
        }
    }

    fn store(&self, unit: &str) -> PathBuf {
        self.root.join(unit)
    }

    fn acquire(&self, unit: &str) -> LockedLifecycle {
        LockedLifecycle::acquire(&self.root, unit, &self.store(unit)).expect("lifecycle lock")
    }
}

fn empty_inventory(args: &[String]) -> RemoteSystemdCommandOutput {
    assert!(matches!(
        args.first().map(String::as_str),
        Some("list-unit-files" | "list-units")
    ));
    RemoteSystemdCommandOutput {
        exit_code: 0,
        stdout: String::new(),
        stderr: String::new(),
    }
}

const EMPTY_INVENTORY: fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError> =
    |args| Ok(empty_inventory(args));

#[test]
fn global_lock_serializes_different_units_and_is_busy_aware() {
    let fixture = Fixture::new();
    let alpha = fixture.acquire("alpha");

    assert!(
        LockedLifecycle::try_acquire(&fixture.root, "beta", &fixture.store("beta"))
            .expect("busy result")
            .is_none()
    );

    drop(alpha);
    let beta = LockedLifecycle::try_acquire(&fixture.root, "beta", &fixture.store("beta"))
        .expect("available result")
        .expect("lock after release");
    assert_eq!(beta.unit(), "beta");
    assert_eq!(beta.store_path(), fixture.store("beta"));
}

#[test]
fn failed_unit_lock_releases_the_global_lock() {
    let fixture = Fixture::new();
    create_private_directory(&fixture.root).expect("transaction root");
    let alpha_store = fixture.store("alpha");
    create_private_directory(&alpha_store).expect("alpha store");
    let _unit_guard = try_acquire_strict_lock(&alpha_store.join(OPERATION_LOCK_FILE))
        .expect("unit lock result")
        .expect("unit lock");

    assert!(
        LockedLifecycle::try_acquire(&fixture.root, "alpha", &alpha_store)
            .expect("busy unit result")
            .is_none()
    );
    assert!(
        LockedLifecycle::try_acquire(&fixture.root, "beta", &fixture.store("beta"))
            .expect("global lock released")
            .is_some()
    );
}

#[test]
fn rejects_store_outside_the_exact_unit_location() {
    let fixture = Fixture::new();
    let error = LockedLifecycle::acquire(
        &fixture.root,
        "alpha",
        &fixture.root.join("alpha").join("nested"),
    )
    .expect_err("nested store");

    assert!(error.to_string().contains("exactly one unit below"));
}

#[test]
fn strict_lock_rejects_symlinks_and_writable_ancestry() {
    let fixture = Fixture::new();
    create_private_directory(&fixture.root).expect("transaction root");
    let target = fixture.root.join("lock-target");
    fs::write(&target, []).expect("lock target");
    fs::set_permissions(&target, Permissions::from_mode(0o600)).expect("lock target mode");
    symlink(&target, fixture.root.join(GLOBAL_LOCK_FILE)).expect("lock symlink");
    assert!(LockedLifecycle::acquire(&fixture.root, "alpha", &fixture.store("alpha")).is_err());

    let temporary = tempdir().expect("temporary directory");
    let writable = temporary.path().join("writable");
    fs::create_dir(&writable).expect("writable ancestor");
    fs::set_permissions(&writable, Permissions::from_mode(0o770)).expect("writable mode");
    let root = writable.join("transactions");
    assert!(LockedLifecycle::acquire(&root, "alpha", &root.join("alpha")).is_err());
}

#[test]
fn trusted_legacy_lock_mode_is_repaired_but_writable_mode_is_rejected() {
    let fixture = Fixture::new();
    create_private_directory(&fixture.root).expect("transaction root");
    let alpha_store = fixture.store("alpha");
    create_private_directory(&alpha_store).expect("alpha store");
    let alpha_lock = alpha_store.join(OPERATION_LOCK_FILE);
    fs::write(&alpha_lock, []).expect("legacy lock");
    fs::set_permissions(&alpha_lock, Permissions::from_mode(0o644)).expect("legacy mode");

    let alpha = fixture.acquire("alpha");
    assert_eq!(
        fs::symlink_metadata(&alpha_lock)
            .expect("repaired lock metadata")
            .mode()
            & 0o7777,
        0o600
    );
    drop(alpha);

    let beta_store = fixture.store("beta");
    create_private_directory(&beta_store).expect("beta store");
    let beta_lock = beta_store.join(OPERATION_LOCK_FILE);
    fs::write(&beta_lock, []).expect("unsafe lock");
    fs::set_permissions(&beta_lock, Permissions::from_mode(0o660)).expect("unsafe mode");
    assert!(LockedLifecycle::acquire(&fixture.root, "beta", &beta_store).is_err());
}

#[test]
fn bind_is_idempotent_and_existing_only_never_adopts() {
    let fixture = Fixture::new();
    assert_existing_only_does_not_adopt(&fixture);
    persist_alpha_claim(&fixture);
    assert_existing_claim_rechecks_inventory(&fixture);
}

fn assert_existing_only_does_not_adopt(fixture: &Fixture) {
    let missing = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::ExistingOnly, &EMPTY_INVENTORY)
        .expect_err("missing existing claim");
    assert!(
        missing
            .to_string()
            .contains("no existing binary ownership claim")
    );
    assert!(!fixture.root.join(".binary-claims.json").exists());
}

fn persist_alpha_claim(fixture: &Fixture) {
    let mut claimed = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("adopt claim");
    assert_eq!(claimed.claim().unit(), "alpha");
    assert_eq!(claimed.claim().binary_path(), fixture.binary);
    assert!(!claimed.claim_is_persisted());
    assert!(!fixture.root.join(".binary-claims.json").exists());
    claimed
        .persist_claim(&EMPTY_INVENTORY)
        .expect("persist adopted claim");
    assert!(claimed.claim_is_persisted());
    claimed.recheck(&EMPTY_INVENTORY).expect("first recheck");
    claimed.recheck(&EMPTY_INVENTORY).expect("second recheck");
    drop(claimed);
}

fn assert_existing_claim_rechecks_inventory(fixture: &Fixture) {
    let inventory_calls = Cell::new(0_u8);
    let counted_inventory = |args: &[String]| {
        inventory_calls.set(inventory_calls.get() + 1);
        Ok(empty_inventory(args))
    };
    let existing = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::ExistingOnly, &counted_inventory)
        .expect("matching claim");
    assert_eq!(existing.claim().binary_path(), fixture.binary);
    assert_eq!(inventory_calls.get(), 2);
}

#[test]
fn provisional_adoption_is_side_effect_free_until_persisted() {
    let fixture = Fixture::new();
    let provisional = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("provisional claim");
    assert!(!provisional.claim_is_persisted());
    drop(provisional);
    assert!(!fixture.root.join(".binary-claims.json").exists());

    let provisional = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("second provisional claim");
    let error = provisional
        .remove_claim()
        .expect_err("provisional claim must not support durable removal");
    assert!(error.to_string().contains("provisional"));
    assert!(!fixture.root.join(".binary-claims.json").exists());
}

#[test]
fn legacy_mode_adopts_but_unit_and_binary_conflicts_fail_closed() {
    let fixture = Fixture::new();
    let other_binary = fixture.binary.with_file_name("other-harness");
    fs::write(&other_binary, b"other").expect("other binary");
    fs::set_permissions(&other_binary, Permissions::from_mode(0o700)).expect("other mode");
    let mut alpha = fixture
        .acquire("alpha")
        .bind(
            &fixture.binary,
            BindMode::LegacyOperationOrMatch,
            &EMPTY_INVENTORY,
        )
        .expect("legacy adoption");
    alpha
        .persist_claim(&EMPTY_INVENTORY)
        .expect("persist legacy adoption");
    drop(alpha);

    let unit_conflict = fixture
        .acquire("alpha")
        .bind(&other_binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect_err("unit conflict");
    assert!(unit_conflict.to_string().contains("already claims binary"));

    let binary_conflict = fixture
        .acquire("beta")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect_err("binary conflict");
    assert!(
        binary_conflict
            .to_string()
            .contains("already claimed by unit alpha")
    );
}

#[test]
fn registry_persists_distinct_claims_in_unit_order() {
    let fixture = Fixture::new();
    let beta_binary = fixture.binary.with_file_name("beta-harness");
    fs::write(&beta_binary, b"beta").expect("beta binary");
    fs::set_permissions(&beta_binary, Permissions::from_mode(0o700)).expect("beta mode");
    let mut beta = fixture
        .acquire("beta")
        .bind(&beta_binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("beta claim");
    beta.persist_claim(&EMPTY_INVENTORY)
        .expect("persist beta claim");
    drop(beta);
    let mut alpha = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("alpha claim");
    alpha
        .persist_claim(&EMPTY_INVENTORY)
        .expect("persist alpha claim");
    drop(alpha);

    let document: Value = serde_json::from_slice(
        &fs::read(fixture.root.join(".binary-claims.json")).expect("registry bytes"),
    )
    .expect("registry JSON");
    let units = document["claims"]
        .as_array()
        .expect("claims array")
        .iter()
        .map(|claim| claim["unit"].as_str().expect("claim unit"))
        .collect::<Vec<_>>();
    assert_eq!(units, ["alpha", "beta"]);
}

#[test]
fn lookup_supports_orphan_uninstall_and_legacy_validation_does_not_adopt() {
    let fixture = Fixture::new();
    let mut claimed = fixture
        .acquire("alpha")
        .bind(&fixture.binary, BindMode::InstallOrMatch, &EMPTY_INVENTORY)
        .expect("claim");
    claimed
        .persist_claim(&EMPTY_INVENTORY)
        .expect("persist claim");
    drop(claimed);

    let locked = fixture.acquire("alpha");
    let claim = locked
        .claim_for_unit()
        .expect("claim lookup")
        .expect("stored claim");
    assert_eq!(claim.unit(), "alpha");
    assert_eq!(claim.binary_path(), fixture.binary);
    drop(locked);

    let legacy_binary = fixture.binary.with_file_name("legacy-harness");
    fs::write(&legacy_binary, b"legacy").expect("legacy binary");
    fs::set_permissions(&legacy_binary, Permissions::from_mode(0o700)).expect("legacy mode");
    fixture
        .acquire("legacy")
        .validate_legacy_uninstall_binary(&legacy_binary, &EMPTY_INVENTORY)
        .expect("legacy inventory validation");
}

#[test]
fn registry_rejects_corruption_duplicates_and_unsafe_claims() {
    let fixture = Fixture::new();
    let locked = fixture.acquire("alpha");
    let binary = fixture.binary.to_str().expect("UTF-8 binary");
    let store_binary = fixture
        .store("alpha")
        .join("claimed-binary")
        .to_str()
        .expect("UTF-8 store binary")
        .to_string();
    let cases = [
        json!({"registry_version": 2, "claims": []}),
        json!({"registry_version": 1, "claims": [], "unknown": true}),
        json!({"registry_version": 1, "claims": [
            raw_claim(2, "alpha", binary, binary)
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "beta", binary, binary),
            raw_claim(1, "alpha", "/other", "/other")
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "alpha", binary, binary),
            raw_claim(1, "beta", binary, binary)
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "alpha", binary, binary),
            raw_claim(1, "alpha", "/other", "/other")
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "alpha", binary, binary),
            raw_claim(1, "beta", "/alias/harness", binary)
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "../alpha", binary, binary)
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "alpha", "relative/harness", binary)
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "alpha", "/tmp/\u{0}harness", binary)
        ]}),
        json!({"registry_version": 1, "claims": [
            raw_claim(1, "alpha", &store_binary, &store_binary)
        ]}),
    ];
    for document in cases {
        write_registry(&fixture.root, &document, 0o600);
        assert!(locked.claim_for_unit().is_err(), "accepted {document}");
    }
}

#[test]
fn registry_rejects_untrusted_mode_symlinks_and_hard_links() {
    let fixture = Fixture::new();
    let locked = fixture.acquire("alpha");
    let registry = fixture.root.join(".binary-claims.json");
    let empty = json!({"registry_version": 1, "claims": []});
    write_registry(&fixture.root, &empty, 0o644);
    assert!(locked.claim_for_unit().is_err());

    fs::remove_file(&registry).expect("remove writable registry");
    let target = fixture.root.join("registry-target");
    write_json_file(&target, &empty, 0o600);
    symlink(&target, &registry).expect("registry symlink");
    assert!(locked.claim_for_unit().is_err());

    fs::remove_file(&registry).expect("remove registry symlink");
    fs::hard_link(&target, &registry).expect("registry hard link");
    assert!(locked.claim_for_unit().is_err());
}

#[test]
fn registry_reconciles_trusted_temporaries_and_rejects_untrusted_debris() {
    let fixture = Fixture::new();
    let locked = fixture.acquire("alpha");
    let trusted = fixture.root.join(".binary-claims.json.tmp-stale");
    fs::write(&trusted, b"partial registry").expect("trusted temporary");
    fs::set_permissions(&trusted, Permissions::from_mode(0o600)).expect("temporary mode");

    assert!(locked.claim_for_unit().expect("reconcile lookup").is_none());
    assert!(!trusted.exists());

    let target = fixture.root.join("temporary-target");
    fs::write(&target, []).expect("temporary target");
    fs::set_permissions(&target, Permissions::from_mode(0o600)).expect("target mode");
    let untrusted = fixture.root.join(".binary-claims.json.tmp-symlink");
    symlink(&target, &untrusted).expect("untrusted temporary");
    assert!(locked.claim_for_unit().is_err());
    assert!(untrusted.exists());
}

fn write_registry(root: &Path, document: &Value, mode: u32) {
    write_json_file(&root.join(".binary-claims.json"), document, mode);
}

fn raw_claim(
    claim_version: u32,
    unit: &str,
    binary_path: &str,
    resolved_binary_path: &str,
) -> Value {
    let entry_name = Path::new(resolved_binary_path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("harness");
    json!({
        "claim_version": claim_version,
        "unit": unit,
        "binary_path": binary_path,
        "resolved_binary_path": resolved_binary_path,
        "parent_device": 1,
        "parent_inode": 1,
        "entry_name": entry_name
    })
}

fn write_json_file(path: &Path, document: &Value, mode: u32) {
    fs::write(
        path,
        serde_json::to_vec_pretty(document).expect("encode JSON"),
    )
    .expect("write JSON");
    fs::set_permissions(path, Permissions::from_mode(mode)).expect("JSON mode");
}
