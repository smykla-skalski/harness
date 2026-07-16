use super::*;

fn recovery_arm(phase: RecoveryPhase, target_database_seal: Option<DatabaseSeal>) -> RecoveryArm {
    RecoveryArm {
        arm_version: RECOVERY_ARM_VERSION,
        transaction_id: "test-transaction".to_string(),
        operation: RecoveryOperation::Upgrade,
        phase,
        unit: "harness-remote".to_string(),
        binary_path: PathBuf::from("/usr/local/bin/harness-daemon"),
        unit_path: PathBuf::from("/etc/systemd/system/harness-remote.service"),
        environment_path: PathBuf::from("/etc/harness/harness-remote.env"),
        state_path: PathBuf::from("/var/lib/harness-remote"),
        store_path: PathBuf::from("/var/lib/harness-transactions/harness-remote"),
        readiness_timeout_seconds: 60,
        stabilization_window_seconds: 5,
        original_enabled: true,
        before_sha256: "before".to_string(),
        target_sha256: "target".to_string(),
        controller_sha256: Some("a".repeat(64)),
        target_database_seal,
    }
}

#[test]
fn absent_and_schema_less_database_seals_remain_distinct() {
    let absent = DatabaseSeal::new(false, None);
    let schema_less = DatabaseSeal::new(true, None);

    absent.validate().expect("absent database seal");
    schema_less.validate().expect("schema-less database seal");
    assert_ne!(absent, schema_less);
}

#[test]
fn absent_database_seal_rejects_schema_version() {
    let error = DatabaseSeal::new(false, Some(35))
        .validate()
        .expect_err("absent database cannot carry schema");

    assert!(error.to_string().contains("cannot record a schema"));
}

#[test]
fn committing_recovery_arm_requires_target_database_seal() {
    let error = recovery_arm(RecoveryPhase::Committing, None)
        .validate()
        .expect_err("unsealed committing arm");

    assert!(error.to_string().contains("no target database seal"));
}

#[test]
fn rollback_ready_arm_accepts_sealed_schema_less_database() {
    recovery_arm(
        RecoveryPhase::RollbackReady,
        Some(DatabaseSeal::new(true, None)),
    )
    .validate()
    .expect("sealed rollback-ready arm");
}

#[test]
fn current_recovery_arm_requires_controller_digest() {
    let mut arm = recovery_arm(RecoveryPhase::Armed, None);
    arm.controller_sha256 = None;

    let error = arm
        .validate()
        .expect_err("v3 arm without controller digest");

    assert!(error.to_string().contains("v3 has no controller digest"));
}

#[test]
fn legacy_recovery_arm_v2_remains_valid_without_controller_digest() {
    let mut arm = recovery_arm(RecoveryPhase::Armed, None);
    arm.arm_version = LEGACY_RECOVERY_ARM_VERSION;
    arm.controller_sha256 = None;

    arm.validate().expect("legacy v2 recovery arm");
}
