use std::fs::{self, Permissions};
use std::path::{Path, PathBuf};

mod remote_systemd;
mod remote_systemd_lifecycle;
mod remote_systemd_plan;
mod remote_systemd_security;
mod remote_systemd_uninstall;
mod remote_systemd_upgrade;

fn trusted_test_executable(root: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = root.join("trusted-bin");
    fs::create_dir_all(&directory).expect("create trusted binary directory");
    fs::set_permissions(&directory, Permissions::from_mode(0o755))
        .expect("secure trusted binary directory");
    let executable = directory.join("harness-daemon");
    fs::write(&executable, "test executable").expect("write test executable");
    fs::set_permissions(&executable, Permissions::from_mode(0o755))
        .expect("secure test executable");
    executable
}
