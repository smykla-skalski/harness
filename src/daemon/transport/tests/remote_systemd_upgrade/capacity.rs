use std::path::Path;

use sha2::{Digest as _, Sha256};

use super::*;

#[test]
fn restore_capacity_sums_every_state_and_file_source() {
    const STATE_HEADROOM: u64 = 16 * 1024 * 1024;
    const FILE_HEADROOM: u64 = 1024 * 1024;

    let fixture = UpgradeFixture::new();
    fs::create_dir_all(&fixture.operation.store_path).expect("create transaction store");
    let first_state = fixture.operation.store_path.join("first-state");
    let second_state = fixture.operation.store_path.join("second-state");
    fs::create_dir_all(&first_state).expect("create first state");
    fs::create_dir_all(&second_state).expect("create second state");
    let first_state_file = first_state.join("unrelated").join("harness.db-wal");
    let second_state_file = second_state.join("second.bin");
    fs::create_dir_all(first_state_file.parent().expect("nested state parent"))
        .expect("create nested state parent");
    fs::write(&first_state_file, vec![1_u8; 4_097]).expect("write first state");
    fs::write(&second_state_file, vec![2_u8; 8_193]).expect("write second state");
    let first_file = fixture.operation.store_path.join("first-artifact");
    let second_file = fixture.operation.store_path.join("second-artifact");
    fs::write(&first_file, vec![3_u8; 12_345]).expect("write first artifact");
    fs::write(&second_file, vec![4_u8; 23_456]).expect("write second artifact");

    let (state_bytes, file_bytes) = required_restore_capacity_for_tests(
        &fixture.operation,
        &[&first_state, &second_state],
        &[&first_file, &second_file],
    )
    .expect("calculate combined restore capacity");

    let allocated_state_bytes = [&first_state_file, &second_state_file]
        .into_iter()
        .map(|path| {
            let metadata = fs::metadata(path).expect("state metadata");
            metadata.len().max(metadata.blocks().saturating_mul(512))
        })
        .sum::<u64>();
    assert_eq!(state_bytes, allocated_state_bytes + STATE_HEADROOM);
    assert_eq!(file_bytes, 12_345 + 23_456 + FILE_HEADROOM);

    let (state_inodes, file_inodes) = required_restore_inodes_for_tests(
        &fixture.operation,
        &[&first_state, &second_state],
        &[&first_file, &second_file],
    )
    .expect("calculate combined restore inode capacity");
    assert_eq!(state_inodes, 5 + 64);
    assert_eq!(file_inodes, 2 + 8);
}

#[test]
fn bidirectional_reserve_includes_both_complete_generations() {
    let fixture = UpgradeFixture::new();
    fs::create_dir_all(&fixture.operation.store_path).expect("create transaction store");
    let first = fixture.operation.store_path.join("first-generation");
    fs::create_dir_all(&first).expect("create first generation");
    snapshot_generation_for_tests(
        &fixture.operation,
        &first,
        &artifact(&fixture.binary, "first"),
    )
    .expect("snapshot first generation");

    write_executable(
        &fixture.binary,
        &format!("{OLD_BINARY}# {}\n", "larger-second-binary".repeat(1_024)),
    );
    fs::write(
        &fixture.unit,
        format!(
            "{}# second generation\n",
            fs::read_to_string(&fixture.unit).expect("read unit")
        ),
    )
    .expect("grow unit");
    fs::write(
        &fixture.operation.environment_path,
        "RUST_LOG=harness=debug\nSECOND_GENERATION=yes\n",
    )
    .expect("grow environment");
    fs::write(fixture.state.join("second-generation"), vec![5_u8; 32_769]).expect("grow state");
    let second = fixture.operation.store_path.join("second-generation");
    fs::create_dir_all(&second).expect("create second generation");
    snapshot_generation_for_tests(
        &fixture.operation,
        &second,
        &artifact(&fixture.binary, "second"),
    )
    .expect("snapshot second generation");

    let state_sources = [first.join("state"), second.join("state")];
    let file_sources = [
        first.join("binary"),
        first.join("unit.service"),
        first.join("environment"),
        second.join("binary"),
        second.join("unit.service"),
        second.join("environment"),
    ];
    let state_refs = state_sources
        .iter()
        .map(PathBuf::as_path)
        .collect::<Vec<_>>();
    let file_refs = file_sources
        .iter()
        .map(PathBuf::as_path)
        .collect::<Vec<_>>();
    let expected = required_restore_capacity_for_tests(&fixture.operation, &state_refs, &file_refs)
        .expect("combined generation capacity");
    let expected_inodes =
        required_restore_inodes_for_tests(&fixture.operation, &state_refs, &file_refs)
            .expect("combined generation inode capacity");

    reserve_bidirectional_restore_capacity_for_tests(&fixture.operation, &first, &second)
        .expect("reserve both rollback directions");

    assert_reserve(
        &fixture.operation.store_path.join("state-restore-reserve"),
        expected.0,
    );
    assert_reserve(
        &fixture
            .binary
            .parent()
            .expect("binary parent")
            .join(format!(
                ".harness-{}-binary-reserve",
                fixture.operation.unit
            )),
        expected.1,
    );
    assert_inode_reserve(
        &fixture
            .operation
            .store_path
            .join("state-restore-inode-reserve"),
        expected_inodes.0,
    );
    assert_inode_reserve(
        &fixture
            .binary
            .parent()
            .expect("binary parent")
            .join(format!(
                ".harness-{}-binary-inode-reserve",
                fixture.operation.unit
            )),
        expected_inodes.1,
    );

    release_restore_capacity_for_tests(&fixture.operation).expect("release rollback capacity");
    assert!(
        !fixture
            .operation
            .store_path
            .join("state-restore-reserve")
            .exists()
    );
    assert!(
        !fixture
            .operation
            .store_path
            .join("state-restore-inode-reserve")
            .exists()
    );
    assert!(
        !fixture
            .binary
            .parent()
            .expect("binary parent")
            .join(format!(
                ".harness-{}-binary-reserve",
                fixture.operation.unit
            ))
            .exists()
    );
    assert!(
        !fixture
            .binary
            .parent()
            .expect("binary parent")
            .join(format!(
                ".harness-{}-binary-inode-reserve",
                fixture.operation.unit
            ))
            .exists()
    );
}

#[test]
fn inode_reserve_rejects_shortage_before_creating_partial_state() {
    let directory = tempfile::tempdir().expect("temporary directory");
    let reserve = directory.path().join("inode-reserve");

    let error = reserve_inode_capacity_with_available_for_tests(&reserve, 4, 4)
        .expect_err("directory plus four placeholders need five inodes");

    assert!(
        error
            .to_string()
            .contains("insufficient rollback inode capacity")
    );
    assert!(
        !reserve.exists(),
        "shortage must not leave partial reserve state"
    );
}

#[test]
fn restore_reconciliation_removes_only_destination_scoped_atomic_debris() {
    let fixture = UpgradeFixture::new();
    fs::create_dir_all(&fixture.operation.store_path).expect("create transaction store");
    let parent = fixture.binary.parent().expect("binary parent");
    let prefix = atomic_copy_temp_prefix_for_tests(&fixture.binary);
    let stale = parent.join(format!("{prefix}interrupted"));
    let unrelated = parent.join(".tmp-unrelated");
    fs::write(&stale, vec![6_u8; 4_096]).expect("write interrupted atomic copy");
    fs::write(&unrelated, "preserve\n").expect("write unrelated temp file");

    reconcile_restore_debris_for_tests(&fixture.operation).expect("reconcile restore debris");

    assert!(!stale.exists());
    assert_eq!(
        fs::read_to_string(unrelated).expect("unrelated file survives"),
        "preserve\n"
    );
}

fn artifact(path: &Path, version: &str) -> RemoteSystemdArtifact {
    let bytes = fs::read(path).expect("read artifact");
    RemoteSystemdArtifact {
        version: version.to_string(),
        sha256: hex::encode(Sha256::digest(bytes)),
        binary_path: path.to_path_buf(),
    }
}

fn assert_reserve(path: &Path, expected: u64) {
    let metadata = fs::metadata(path).expect("reserve metadata");
    assert_eq!(metadata.len(), expected);
    #[cfg(target_os = "linux")]
    assert!(metadata.blocks().saturating_mul(512) >= expected);
}

fn assert_inode_reserve(path: &Path, expected: u64) {
    let metadata = fs::symlink_metadata(path).expect("inode reserve metadata");
    assert!(metadata.is_dir());
    let count = fs::read_dir(path)
        .expect("read inode reserve")
        .map(|entry| entry.expect("inode reserve entry"))
        .count();
    assert_eq!(u64::try_from(count).expect("inode reserve count"), expected);
}
