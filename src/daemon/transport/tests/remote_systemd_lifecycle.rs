use std::path::{Path, PathBuf};

use clap::Parser;
use tempfile::tempdir;

use super::super::remote_systemd::{DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, install_remote_systemd_with,
};

#[cfg(unix)]
#[test]
fn remote_systemd_install_does_not_stage_secret_when_env_exists() {
    use std::os::unix::fs::PermissionsExt as _;

    let temp = tempdir().expect("temp dir");
    let env_parent = temp.path().join("harness");
    let env_path = env_parent.join("remote-daemon.env");
    std::fs::create_dir_all(&env_parent).expect("env dir");
    std::fs::write(&env_path, "PREPROVISIONED_SECRET=value\n").expect("write env");
    std::fs::set_permissions(&env_parent, std::fs::Permissions::from_mode(0o500))
        .expect("make env directory read-only");
    let plan = install_plan(temp.path(), env_path.clone());

    let result = install_remote_systemd_with(&plan, &successful_runner);
    std::fs::set_permissions(&env_parent, std::fs::Permissions::from_mode(0o700))
        .expect("restore env directory permissions");
    let report = result.expect("existing env file does not require a temp file");

    assert!(!report.env_written);
    assert_eq!(
        std::fs::read_to_string(env_path).expect("read env"),
        "PREPROVISIONED_SECRET=value\n"
    );
}

#[cfg(unix)]
#[test]
fn remote_systemd_install_rejects_symlink_environment_path() {
    use std::os::unix::fs::{PermissionsExt as _, symlink};

    let temp = tempdir().expect("temp dir");
    let env_parent = temp.path().join("harness");
    let target_path = temp.path().join("unrelated-secret");
    let env_path = env_parent.join("remote-daemon.env");
    std::fs::create_dir_all(&env_parent).expect("env dir");
    std::fs::write(&target_path, "DO_NOT_TOUCH\n").expect("write target");
    std::fs::set_permissions(&target_path, std::fs::Permissions::from_mode(0o640))
        .expect("set target mode");
    symlink(&target_path, &env_path).expect("create env symlink");
    let plan = install_plan(temp.path(), env_path);

    let error = install_remote_systemd_with(&plan, &successful_runner)
        .expect_err("symlink environment path must be rejected");

    assert!(error.to_string().contains("symbolic link"));
    assert_eq!(
        std::fs::read_to_string(&target_path).expect("read target"),
        "DO_NOT_TOUCH\n"
    );
    let mode = std::fs::metadata(target_path)
        .expect("target metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o640);
}

fn install_plan(root: &Path, env_path: PathBuf) -> RemoteSystemdInstallPlan {
    let args = install_args();
    RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        root.join("systemd").join("harness-remote-daemon.service"),
        env_path,
    )
    .expect("systemd install plan")
}

fn install_args() -> DaemonRemoteSystemdInstallArgs {
    #[derive(Debug, Parser)]
    struct Harness {
        #[command(flatten)]
        args: DaemonRemoteSystemdInstallArgs,
    }

    Harness::try_parse_from([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ])
    .expect("parse install args")
    .args
}

fn successful_runner(
    _args: &[String],
) -> Result<RemoteSystemdCommandOutput, crate::errors::CliError> {
    Ok(RemoteSystemdCommandOutput {
        exit_code: 0,
        stdout: String::new(),
        stderr: String::new(),
    })
}
