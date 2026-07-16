use std::fs;
#[cfg(target_os = "linux")]
use std::fs::File;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};

use tempfile::TempDir;

#[cfg(target_os = "linux")]
use nix::fcntl::{FcntlArg, fcntl};
#[cfg(target_os = "linux")]
use nix::unistd::close;

use super::{
    PERMIT_PREFIX, install_runtime_start_permit, remove_stale_runtime_start_permit,
    require_runtime_start_permit_absent, runtime_start_permit_is_live, runtime_start_permit_path,
    trusted_gid, trusted_uid,
};

const UNRELATED_PERMIT_BYTES: &[u8] = b"[Unit]\nDescription=unrelated\n";

fn trusted_temp() -> TempDir {
    TempDir::new_in(env!("CARGO_MANIFEST_DIR")).expect("create trusted temp directory")
}

fn unit_path(temp: &TempDir) -> PathBuf {
    let systemd = temp.path().join("etc/systemd/system");
    fs::create_dir_all(&systemd).expect("create test systemd directory");
    systemd.join("harness-remote.service")
}

fn condition_path(permit_path: &Path) -> PathBuf {
    let contents = fs::read_to_string(permit_path).expect("read runtime permit");
    let value = contents
        .strip_prefix(PERMIT_PREFIX)
        .and_then(|condition| condition.strip_suffix('\n'))
        .expect("exact runtime permit contents");
    PathBuf::from(value)
}

#[test]
fn permit_condition_is_live_only_while_guard_is_held() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let permit = install_runtime_start_permit(&unit).expect("install runtime permit");
    let path = permit.path().to_path_buf();
    let condition = condition_path(&path);

    assert!(condition.exists());
    assert_live_condition_path(&condition);
    assert!(runtime_start_permit_is_live(&unit).expect("inspect live permit"));

    drop(permit);

    assert!(path.exists());
    assert!(!condition.exists());
    assert!(!runtime_start_permit_is_live(&unit).expect("inspect stale permit"));
    assert!(remove_stale_runtime_start_permit(&unit).expect("remove stale permit"));
    require_runtime_start_permit_absent(&unit).expect("permit must be absent");
}

#[cfg(target_os = "linux")]
fn assert_live_condition_path(condition: &Path) {
    assert!(condition.starts_with("/proc/"));
}

#[cfg(not(target_os = "linux"))]
fn assert_live_condition_path(condition: &Path) {
    assert!(condition.is_absolute());
    assert!(!condition.starts_with("/proc/"));
}

#[test]
#[cfg(target_os = "linux")]
fn replacement_high_descriptor_cannot_satisfy_the_uuid_condition() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let mut permit = install_runtime_start_permit(&unit).expect("install runtime permit");
    let permit_path = permit.path().to_path_buf();
    let condition = condition_path(&permit_path);
    let descriptor = condition
        .components()
        .nth_back(1)
        .and_then(|component| component.as_os_str().to_str())
        .and_then(|value| value.parse::<i32>().ok())
        .expect("condition descriptor");
    let token_name = condition.file_name().expect("condition token");

    permit
        .close_liveness_descriptor_for_tests()
        .expect("close original liveness descriptor");
    assert!(!condition.exists());
    assert!(!runtime_start_permit_is_live(&unit).expect("inspect closed permit"));

    let replacement_source = File::open("/").expect("open replacement descriptor source");
    let replacement = fcntl(&replacement_source, FcntlArg::F_DUPFD_CLOEXEC(descriptor))
        .expect("duplicate replacement descriptor");
    let replacement_descriptor = PathBuf::from(format!("/proc/self/fd/{replacement}"));
    let replacement_condition = replacement_descriptor.join(token_name);
    assert!(replacement_descriptor.exists());
    assert!(!replacement_condition.exists());
    assert!(!condition.exists());
    close(replacement).expect("close replacement descriptor");

    drop(permit);
    assert!(remove_stale_runtime_start_permit(&unit).expect("remove stale permit"));
}

#[test]
fn owned_removal_preserves_unrelated_drop_in() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let permit = install_runtime_start_permit(&unit).expect("install runtime permit");
    let permit_path = permit.path().to_path_buf();
    let drop_in_directory = permit_path.parent().expect("permit parent");
    let unrelated = drop_in_directory.join("95-unrelated.conf");
    fs::write(&unrelated, b"[Unit]\nDescription=unrelated\n").expect("write unrelated drop-in");

    permit.remove().expect("remove owned permit");

    assert!(!permit_path.exists());
    assert!(unrelated.exists());
    assert!(drop_in_directory.exists());
    require_runtime_start_permit_absent(&unit).expect("permit must be absent");
}

#[test]
fn live_permit_is_never_removed_as_stale() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let permit = install_runtime_start_permit(&unit).expect("install runtime permit");
    let path = permit.path().to_path_buf();

    let error = remove_stale_runtime_start_permit(&unit).expect_err("live permit must be refused");

    assert!(error.to_string().contains("refusing to remove a live"));
    assert!(path.exists());
    permit.remove().expect("remove owned live permit");
}

#[test]
fn unrelated_file_at_permit_path_is_refused_and_preserved() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let path = runtime_start_permit_path(&unit).expect("derive permit path");
    let parent = path.parent().expect("permit parent");
    fs::create_dir_all(parent).expect("create runtime control directories");
    fs::set_permissions(
        parent.parent().expect("runtime control root"),
        fs::Permissions::from_mode(0o755),
    )
    .expect("set runtime control root permissions");
    fs::set_permissions(parent, fs::Permissions::from_mode(0o755))
        .expect("set drop-in permissions");
    fs::write(&path, UNRELATED_PERMIT_BYTES).expect("write unrelated file");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
        .expect("set unrelated file permissions");

    let error = remove_stale_runtime_start_permit(&unit)
        .expect_err("unrelated permit contents must be refused");

    assert!(error.to_string().contains("refusing unrelated"));
    assert_eq!(
        fs::read(&path).expect("read preserved unrelated file"),
        UNRELATED_PERMIT_BYTES
    );
}

#[test]
fn symlink_at_permit_path_is_refused_and_preserved() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let path = runtime_start_permit_path(&unit).expect("derive permit path");
    let parent = path.parent().expect("permit parent");
    fs::create_dir_all(parent).expect("create runtime control directories");
    fs::set_permissions(
        parent.parent().expect("runtime control root"),
        fs::Permissions::from_mode(0o755),
    )
    .expect("set runtime control root permissions");
    fs::set_permissions(parent, fs::Permissions::from_mode(0o755))
        .expect("set drop-in permissions");
    symlink("/", &path).expect("create unrelated symlink");

    let error =
        remove_stale_runtime_start_permit(&unit).expect_err("symlink permit must be refused");

    assert!(error.to_string().contains("not a regular file"));
    assert!(
        fs::symlink_metadata(&path)
            .expect("preserved symlink")
            .file_type()
            .is_symlink()
    );
}

#[test]
fn installed_permit_has_exact_path_contents_and_metadata() {
    let temp = trusted_temp();
    let unit = unit_path(&temp);
    let permit = install_runtime_start_permit(&unit).expect("install runtime permit");
    let expected = unit
        .parent()
        .expect("unit parent")
        .join("run-systemd-system.control")
        .join("harness-remote.service.d")
        .join("90-harness-inhibit.conf");

    assert_eq!(permit.path(), expected);
    let contents = fs::read_to_string(&expected).expect("read runtime permit");
    assert!(contents.starts_with(PERMIT_PREFIX));
    assert!(contents.ends_with('\n'));
    assert_permit_metadata(&expected);

    permit.remove().expect("remove owned permit");
}

fn assert_permit_metadata(path: &Path) {
    let metadata = fs::symlink_metadata(path).expect("inspect runtime permit");
    assert!(metadata.is_file());
    assert_eq!(metadata.mode() & 0o7777, 0o644);
    assert_eq!(metadata.nlink(), 1);
    assert_eq!(metadata.uid(), trusted_uid());
    assert_eq!(metadata.gid(), trusted_gid());
}
