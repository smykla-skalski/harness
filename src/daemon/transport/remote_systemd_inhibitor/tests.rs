use std::fs::Permissions;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _, symlink};

use fs_err as fs;
use tempfile::TempDir;

use super::*;

fn trusted_temp() -> TempDir {
    TempDir::new_in(env!("CARGO_MANIFEST_DIR")).expect("create trusted temp directory")
}

fn unit_path(root: &Path) -> PathBuf {
    root.join("harness-daemon.service")
}

fn create_drop_in_directory(path: &Path) {
    fs::create_dir(path).expect("drop-in directory");
    fs::set_permissions(path, Permissions::from_mode(0o755)).expect("canonical directory mode");
}

#[test]
fn exact_inhibitor_install_is_idempotent() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let expected = temporary
        .path()
        .join("harness-daemon.service.d")
        .join(INHIBITOR_FILE_NAME);

    assert_eq!(install_inhibitor(&unit).expect("first install"), expected);
    assert_eq!(install_inhibitor(&unit).expect("second install"), expected);
    assert!(inhibitor_is_installed(&unit).expect("query installed inhibitor"));
    assert_eq!(
        fs::read(&expected).expect("inhibitor bytes"),
        INHIBITOR_BYTES
    );
    let metadata = fs::symlink_metadata(&expected).expect("inhibitor metadata");
    assert!(metadata.is_file());
    assert_eq!(metadata.uid(), trusted_uid());
    assert_eq!(metadata.gid(), trusted_gid());
    assert_eq!(metadata.mode() & 0o7777, 0o644);
    assert_eq!(metadata.nlink(), 1);
    let directory_metadata = fs::symlink_metadata(expected.parent().expect("drop-in directory"))
        .expect("drop-in directory metadata");
    assert_eq!(directory_metadata.uid(), trusted_uid());
    assert_eq!(directory_metadata.gid(), trusted_gid());
    assert_eq!(directory_metadata.mode() & 0o7777, 0o755);
}

#[test]
fn unrelated_inhibitor_is_never_replaced_or_removed() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = inhibitor_path(&unit).expect("inhibitor path");
    let directory = path.parent().expect("drop-in directory");
    create_drop_in_directory(directory);
    fs::write(&path, b"[Unit]\nDescription=unrelated\n").expect("unrelated drop-in");
    fs::set_permissions(&path, Permissions::from_mode(0o644))
        .expect("canonical unrelated drop-in mode");

    let install_error = install_inhibitor(&unit).expect_err("unrelated install must fail");
    let remove_error = remove_inhibitor(&unit).expect_err("unrelated removal must fail");

    assert!(install_error.to_string().contains("unrelated"));
    assert!(remove_error.to_string().contains("unrelated"));
    assert_eq!(
        fs::read(&path).expect("preserved unrelated drop-in"),
        b"[Unit]\nDescription=unrelated\n"
    );
}

#[test]
fn symbolic_link_inhibitor_is_never_followed() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = inhibitor_path(&unit).expect("inhibitor path");
    create_drop_in_directory(path.parent().expect("drop-in directory"));
    let target = temporary.path().join("target.conf");
    fs::write(&target, INHIBITOR_BYTES).expect("target contents");
    symlink(&target, &path).expect("inhibitor symlink");

    assert!(inhibitor_is_installed(&unit).is_err());
    assert!(install_inhibitor(&unit).is_err());
    assert!(remove_inhibitor(&unit).is_err());
    assert_eq!(
        fs::read(&target).expect("preserved target"),
        INHIBITOR_BYTES
    );
    assert!(
        fs::symlink_metadata(&path)
            .expect("preserved symlink")
            .file_type()
            .is_symlink()
    );
}

#[test]
fn exact_removal_is_idempotent_and_removes_the_empty_owned_directory() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = install_inhibitor(&unit).expect("install inhibitor");
    let directory = path.parent().expect("drop-in directory").to_path_buf();

    assert!(remove_inhibitor(&unit).expect("first removal"));
    assert!(!path.exists());
    assert!(!directory.exists());
    assert!(!remove_inhibitor(&unit).expect("second removal"));
    assert!(!inhibitor_is_installed(&unit).expect("query absent inhibitor"));
}

#[test]
fn removal_preserves_unrelated_drop_ins_and_their_directory() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = install_inhibitor(&unit).expect("install inhibitor");
    let directory = path.parent().expect("drop-in directory");
    let unrelated = directory.join("50-local.conf");
    fs::write(&unrelated, b"[Unit]\nDescription=local\n").expect("unrelated drop-in");

    assert!(remove_inhibitor(&unit).expect("remove exact inhibitor"));
    assert!(!path.exists());
    assert_eq!(
        fs::read(&unrelated).expect("preserved unrelated drop-in"),
        b"[Unit]\nDescription=local\n"
    );
    assert!(directory.exists());
}

#[test]
fn writable_inhibitor_is_rejected_without_removal() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = install_inhibitor(&unit).expect("install inhibitor");
    fs::set_permissions(&path, Permissions::from_mode(0o666)).expect("writable permissions");

    let error = remove_inhibitor(&unit).expect_err("writable inhibitor must fail closed");

    assert!(error.to_string().contains("mode 0644"));
    assert_eq!(
        fs::read(&path).expect("preserved inhibitor"),
        INHIBITOR_BYTES
    );
}

#[test]
fn restrictive_inhibitor_mode_is_rejected_without_removal() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = install_inhibitor(&unit).expect("install inhibitor");
    fs::set_permissions(&path, Permissions::from_mode(0o600)).expect("restrictive permissions");

    let error = remove_inhibitor(&unit).expect_err("noncanonical inhibitor mode must fail closed");

    assert!(error.to_string().contains("mode 0644"));
    assert_eq!(
        fs::read(&path).expect("preserved inhibitor"),
        INHIBITOR_BYTES
    );
}

#[test]
fn hard_linked_inhibitor_is_rejected_without_removal() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = install_inhibitor(&unit).expect("install inhibitor");
    let alias = temporary.path().join("inhibitor-alias");
    fs::hard_link(&path, &alias).expect("hard link inhibitor");

    let error = remove_inhibitor(&unit).expect_err("hard-linked inhibitor must fail closed");

    assert!(error.to_string().contains("exactly one hard link"));
    assert_eq!(fs::read(&alias).expect("preserved alias"), INHIBITOR_BYTES);
}

#[test]
fn noncanonical_drop_in_directory_mode_is_rejected() {
    let temporary = trusted_temp();
    let unit = unit_path(temporary.path());
    let path = install_inhibitor(&unit).expect("install inhibitor");
    let directory = path.parent().expect("drop-in directory");
    fs::set_permissions(directory, Permissions::from_mode(0o700))
        .expect("restrictive directory permissions");

    let error = inhibitor_is_installed(&unit)
        .expect_err("noncanonical inhibitor directory mode must fail closed");

    assert!(error.to_string().contains("mode 0755"));
    assert_eq!(
        fs::read(&path).expect("preserved inhibitor"),
        INHIBITOR_BYTES
    );
}
