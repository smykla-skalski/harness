use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::time::Duration;

use serde_json::Value;
use tempfile::tempdir;

use super::*;

struct Fixture {
    _temp: tempfile::TempDir,
    daemon: PathBuf,
    controller: PathBuf,
    store: PathBuf,
    plan: RemoteSystemdOperationPlan,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempdir().expect("temporary release pair");
        let daemon = temp.path().join("harness-daemon");
        let controller = temp.path().join("harness-systemd");
        write_executable(&daemon, b"daemon-v1");
        write_executable(&controller, b"controller-v1");
        let store = temp.path().join("transactions").join("harness-remote");
        establish_locked_release_pair("harness-remote", &daemon, &controller, &store)
            .expect("establish release pair");
        let plan = RemoteSystemdOperationPlan {
            unit: "harness-remote".to_string(),
            binary_path: daemon.clone(),
            unit_path: temp.path().join("harness-remote.service"),
            environment_path: temp.path().join("harness-remote.env"),
            state_path: temp.path().join("state").join("harness"),
            store_path: store.clone(),
            controller_path: controller.clone(),
            readiness_timeout: Duration::from_secs(1),
            stabilization_window: Duration::ZERO,
        };
        Self {
            _temp: temp,
            daemon,
            controller,
            store,
            plan,
        }
    }
}

#[test]
fn release_pair_binds_separate_controller_and_daemon() {
    let fixture = Fixture::new();

    verify_trusted_controller(&fixture.plan).expect("trusted release pair");
    let document: Value = serde_json::from_slice(
        &fs::read(fixture.store.join(RELEASE_PAIR_FILE)).expect("read release pair"),
    )
    .expect("decode release pair");

    assert_eq!(document["record_version"], RELEASE_PAIR_RECORD_VERSION);
    assert_eq!(
        document["lifecycle_protocol_version"],
        LIFECYCLE_PROTOCOL_VERSION
    );
    assert_eq!(document["canonical_unit"], "harness-remote");
    assert_eq!(
        document["daemon_path"].as_str(),
        fixture
            .daemon
            .canonicalize()
            .expect("canonical daemon")
            .to_str()
    );
    assert_eq!(
        document["controller_path"].as_str(),
        fixture
            .controller
            .canonicalize()
            .expect("canonical controller")
            .to_str()
    );
    assert_ne!(document["daemon_sha256"], document["controller_sha256"]);
}

#[test]
fn release_pair_rejects_daemon_and_controller_tampering() {
    let fixture = Fixture::new();
    write_executable(&fixture.daemon, b"daemon-tampered");
    let daemon_error =
        verify_trusted_controller(&fixture.plan).expect_err("tampered daemon must fail");
    assert!(daemon_error.to_string().contains("installed daemon digest"));

    write_executable(&fixture.daemon, b"daemon-v1");
    write_executable(&fixture.controller, b"controller-tampered");
    let controller_error =
        verify_trusted_controller(&fixture.plan).expect_err("tampered controller must fail");
    assert!(controller_error.to_string().contains("controller digest"));
}

#[test]
fn uninstall_requires_the_paired_controller_but_allows_legacy_absence() {
    let fixture = Fixture::new();

    verify_uninstall_controller("harness-remote", &fixture.controller, &fixture.store)
        .expect("paired controller authorizes uninstall");
    write_executable(&fixture.controller, b"controller-tampered");
    let error = verify_uninstall_controller("harness-remote", &fixture.controller, &fixture.store)
        .expect_err("tampered controller must not authorize uninstall");
    assert!(error.to_string().contains("controller digest"));

    remove_release_pair(&fixture.store).expect("remove pair");
    verify_uninstall_controller("harness-remote", &fixture.controller, &fixture.store)
        .expect("legacy installation without pair remains uninstallable");
}

#[test]
fn install_is_idempotent_and_rejects_same_release_rebinding() {
    let fixture = Fixture::new();
    establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &fixture.controller,
        &fixture.store,
    )
    .expect("idempotent release pair");
    let replacement = fixture.controller.with_file_name("replacement-controller");
    write_executable(&replacement, b"controller-v2");

    let error = establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &replacement,
        &fixture.store,
    )
    .expect_err("install must not rebind controller trust");

    assert!(error.to_string().contains("stale or same-release"));
}

#[test]
fn newer_controller_rotates_only_while_the_pair_is_idle() {
    let fixture = Fixture::new();
    rewrite_release_identity(&fixture.store, "harness-systemd/47.0.0");
    let replacement = fixture.controller.with_file_name("harness-systemd-v48");
    write_executable(&replacement, b"controller-v48");

    establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &replacement,
        &fixture.store,
    )
    .expect("rotate idle controller");

    let record = load_record(&fixture.store)
        .expect("load rotated record")
        .expect("rotated record");
    assert_eq!(record.release_identity, release_identity());
    assert_eq!(
        record.controller_path,
        replacement.canonicalize().expect("canonical replacement")
    );
}

#[test]
fn newer_controller_can_rotate_after_same_path_atomic_replacement() {
    let fixture = Fixture::new();
    rewrite_release_identity(&fixture.store, "harness-systemd/47.0.0");
    write_executable(&fixture.controller, b"controller-v48");

    establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &fixture.controller,
        &fixture.store,
    )
    .expect("rotate same-path controller");

    let record = load_record(&fixture.store)
        .expect("load rotated record")
        .expect("rotated record");
    assert_eq!(record.release_identity, release_identity());
    assert_eq!(
        record.controller_sha256,
        sha256_file(&fixture.controller).expect("replacement digest")
    );
}

#[test]
fn newer_controller_can_rotate_after_old_release_is_reaped() {
    let fixture = Fixture::new();
    rewrite_release_identity(&fixture.store, "harness-systemd/47.0.0");
    fs::remove_file(&fixture.controller).expect("remove old controller");
    let replacement = fixture.controller.with_file_name("harness-systemd-v48");
    write_executable(&replacement, b"controller-v48");

    establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &replacement,
        &fixture.store,
    )
    .expect("rotate after old controller removal");

    let record = load_record(&fixture.store)
        .expect("load rotated record")
        .expect("rotated record");
    assert_eq!(
        record.controller_path,
        replacement.canonicalize().expect("canonical replacement")
    );
}

#[test]
fn armed_transaction_blocks_controller_rotation_without_rewriting_the_pair() {
    let fixture = Fixture::new();
    rewrite_release_identity(&fixture.store, "harness-systemd/47.0.0");
    let before = fs::read(fixture.store.join(RELEASE_PAIR_FILE)).expect("pair before arm");
    fs::write(fixture.store.join(RECOVERY_ARM_FILE), b"legacy arm v2")
        .expect("write legacy arm marker");
    let replacement = fixture.controller.with_file_name("harness-systemd-v48");
    write_executable(&replacement, b"controller-v48");

    let error = establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &replacement,
        &fixture.store,
    )
    .expect_err("armed controller rotation must fail");

    assert!(error.to_string().contains("recovery arm"));
    assert_eq!(
        fs::read(fixture.store.join(RELEASE_PAIR_FILE)).expect("pair after rejection"),
        before
    );
}

#[test]
fn controller_rotation_rejects_untrusted_candidate_permissions() {
    let fixture = Fixture::new();
    rewrite_release_identity(&fixture.store, "harness-systemd/47.0.0");
    let replacement = fixture.controller.with_file_name("harness-systemd-v48");
    write_executable(&replacement, b"controller-v48");
    fs::set_permissions(&replacement, fs::Permissions::from_mode(0o777))
        .expect("make replacement untrusted");

    let error = establish_locked_release_pair(
        "harness-remote",
        &fixture.daemon,
        &replacement,
        &fixture.store,
    )
    .expect_err("untrusted controller candidate must fail");

    assert!(error.to_string().contains("group or world writable"));
}

#[test]
fn trusted_controller_accepts_armed_target_daemon_digest() {
    let fixture = Fixture::new();
    let before = sha256_file(&fixture.daemon).expect("before digest");
    write_executable(&fixture.daemon, b"daemon-v2");
    let target = sha256_file(&fixture.daemon).expect("target digest");
    write_json_atomic(
        &fixture.store.join(RECOVERY_ARM_FILE),
        &recovery_arm(&fixture, before, target),
    )
    .expect("write recovery arm");

    verify_trusted_controller(&fixture.plan)
        .expect("paired controller may resume its armed target daemon");
}

#[test]
fn recovery_copy_is_trusted_by_digest_even_at_its_immutable_path() {
    let fixture = Fixture::new();
    let recovery_controller = fixture.plan.recovery_controller_path();
    fs::copy(&fixture.controller, &recovery_controller).expect("copy recovery controller");
    fs::set_permissions(&recovery_controller, fs::Permissions::from_mode(0o700))
        .expect("secure recovery controller");
    let daemon_sha256 = sha256_file(&fixture.daemon).expect("daemon digest");
    let arm = recovery_arm(&fixture, daemon_sha256.clone(), daemon_sha256);

    verify_recovery_controller(&fixture.plan, &arm)
        .expect("immutable recovery copy trusted by paired digest");
}

#[test]
fn production_recovery_source_hashes_the_immutable_copy_not_proc_self_exe() {
    let fixture = Fixture::new();
    let recovery_controller = fixture.plan.recovery_controller_path();
    fs::copy(&fixture.controller, &recovery_controller).expect("copy recovery controller");
    fs::set_permissions(&recovery_controller, fs::Permissions::from_mode(0o700))
        .expect("secure recovery controller");
    let daemon_sha256 = sha256_file(&fixture.daemon).expect("daemon digest");
    let arm = recovery_arm(&fixture, daemon_sha256.clone(), daemon_sha256);
    let mut production_plan = fixture.plan;
    production_plan.controller_path = PathBuf::from("/proc/self/exe");

    verify_recovery_controller(&production_plan, &arm)
        .expect("production recovery verifies the immutable copied controller");
}

#[test]
fn missing_pair_preserves_legacy_armed_recovery_copy_authority() {
    let fixture = Fixture::new();
    remove_release_pair(&fixture.store).expect("remove pair to model legacy transaction");
    let recovery_controller = fixture.plan.recovery_controller_path();
    fs::copy(&fixture.daemon, &recovery_controller).expect("copy legacy recovery controller");
    fs::set_permissions(&recovery_controller, fs::Permissions::from_mode(0o700))
        .expect("secure legacy recovery controller");
    let before = sha256_file(&fixture.daemon).expect("legacy before digest");
    let mut arm = recovery_arm(&fixture, before.clone(), before);
    arm.arm_version = super::super::model::LEGACY_RECOVERY_ARM_VERSION;
    arm.controller_sha256 = None;

    verify_recovery_controller(&fixture.plan, &arm)
        .expect("legacy immutable controller remains authoritative");
}

fn write_executable(path: &Path, contents: &[u8]) {
    fs::write(path, contents).expect("write executable");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("make executable trusted");
}

fn rewrite_release_identity(store: &Path, identity: &str) {
    let path = store.join(RELEASE_PAIR_FILE);
    let mut document: Value = serde_json::from_slice(&fs::read(&path).expect("read release pair"))
        .expect("decode release pair");
    document["release_identity"] = Value::String(identity.to_string());
    write_json_atomic(
        &path,
        &serde_json::from_value::<ReleasePairRecord>(document)
            .expect("decode rewritten release pair"),
    )
    .expect("rewrite release pair identity");
}

fn recovery_arm(fixture: &Fixture, before_sha256: String, target_sha256: String) -> RecoveryArm {
    RecoveryArm {
        arm_version: super::super::model::RECOVERY_ARM_VERSION,
        transaction_id: "transaction".to_string(),
        operation: super::super::model::RecoveryOperation::Upgrade,
        phase: super::super::model::RecoveryPhase::RollbackReady,
        unit: fixture.plan.unit.clone(),
        binary_path: fixture.plan.binary_path.clone(),
        unit_path: fixture.plan.unit_path.clone(),
        environment_path: fixture.plan.environment_path.clone(),
        state_path: fixture.plan.state_path.clone(),
        store_path: fixture.plan.store_path.clone(),
        readiness_timeout_seconds: 1,
        stabilization_window_seconds: 0,
        original_enabled: true,
        before_sha256,
        target_sha256,
        controller_sha256: Some(sha256_file(&fixture.controller).expect("controller digest")),
        target_database_seal: None,
    }
}
