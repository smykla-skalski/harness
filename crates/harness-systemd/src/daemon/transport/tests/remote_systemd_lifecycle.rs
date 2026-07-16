use std::cell::Cell;
use std::fs::{self, Permissions};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};

use clap::Parser;
use tempfile::tempdir;

use crate::errors::CliError;

use super::super::remote_systemd::{DaemonRemoteSystemdInstallArgs, RemoteSystemdInstallPlan};
use super::super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, effective_install_show_for_tests, install_remote_systemd_with,
    install_remote_systemd_with_pre_enable,
};
use super::trusted_test_executable;

#[cfg(unix)]
#[test]
fn remote_systemd_install_does_not_stage_secret_when_env_exists() {
    let temp = tempdir().expect("temp dir");
    let env_parent = temp.path().join("harness");
    let env_path = env_parent.join("remote-daemon.env");
    fs::create_dir_all(&env_parent).expect("env dir");
    fs::write(&env_path, "PREPROVISIONED_SECRET=value\n").expect("write env");
    fs::set_permissions(&env_parent, Permissions::from_mode(0o500))
        .expect("make env directory read-only");
    let plan = install_plan(temp.path(), env_path.clone());

    let result = install_remote_systemd_with(&plan, &|args| Ok(successful_output(&plan, args)));
    fs::set_permissions(&env_parent, Permissions::from_mode(0o700))
        .expect("restore env directory permissions");
    let report = result.expect("existing env file does not require a temp file");

    assert!(!report.env_written);
    assert_eq!(
        fs::read_to_string(env_path).expect("read env"),
        "PREPROVISIONED_SECRET=value\n"
    );
}

#[cfg(unix)]
#[test]
fn remote_systemd_install_rejects_symlink_environment_path() {
    let temp = tempdir().expect("temp dir");
    let env_parent = temp.path().join("harness");
    let target_path = temp.path().join("unrelated-secret");
    let env_path = env_parent.join("remote-daemon.env");
    fs::create_dir_all(&env_parent).expect("env dir");
    fs::write(&target_path, "DO_NOT_TOUCH\n").expect("write target");
    fs::set_permissions(&target_path, Permissions::from_mode(0o640)).expect("set target mode");
    symlink(&target_path, &env_path).expect("create env symlink");
    let plan = install_plan(temp.path(), env_path);

    let error = install_remote_systemd_with(&plan, &|args| Ok(successful_output(&plan, args)))
        .expect_err("symlink environment path must be rejected");

    assert!(error.to_string().contains("symbolic link"));
    assert_eq!(
        fs::read_to_string(&target_path).expect("read target"),
        "DO_NOT_TOUCH\n"
    );
    let mode = fs::metadata(target_path)
        .expect("target metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o640);
}

#[test]
fn remote_systemd_install_rejects_protected_environment_override_before_systemctl() {
    for name in ["XDG_DATA_HOME", "STATE_DIRECTORY"] {
        assert_protected_override_rejected(name);
    }
}

fn assert_protected_override_rejected(name: &str) {
    let temp = tempdir().expect("temp dir");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    fs::create_dir_all(env_path.parent().expect("environment parent"))
        .expect("create environment parent");
    fs::write(&env_path, format!("{name}=/tmp/untracked\n")).expect("write protected override");
    let plan = install_plan(temp.path(), env_path);
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("protected environment override must fail before systemctl")
    };

    let error = install_remote_systemd_with(&plan, &runner)
        .expect_err("protected environment override must be rejected");

    assert!(
        error
            .to_string()
            .contains(&format!("protected variable {name}"))
    );
}

#[test]
fn remote_systemd_install_rejects_effective_drop_ins_before_start() {
    let temp = tempdir().expect("temp dir");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    let plan = install_plan(temp.path(), env_path);
    let runner = |args: &[String]| {
        let stdout = if args.first().map(String::as_str) == Some("show") {
            format!(
                "LoadState=loaded\nFragmentPath={}\nDropInPaths=/etc/systemd/system/override.conf\n",
                plan.unit_path.display()
            )
        } else {
            String::new()
        };
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout,
            stderr: String::new(),
        })
    };

    let before_enable_called = Cell::new(false);
    let mut before_enable = || {
        before_enable_called.set(true);
        Ok(())
    };
    let error = install_remote_systemd_with_pre_enable(&plan, &runner, &mut before_enable)
        .expect_err("effective drop-in must prevent start");

    assert!(error.to_string().contains("unexpected effective sources"));
    assert!(!before_enable_called.get());
}

#[cfg(unix)]
#[test]
fn remote_systemd_install_secures_exact_existing_unit_and_environment() {
    let temp = tempdir().expect("temp dir");
    let env_path = temp.path().join("harness").join("remote-daemon.env");
    let plan = install_plan(temp.path(), env_path.clone());
    install_remote_systemd_with(&plan, &|args| Ok(successful_output(&plan, args)))
        .expect("initial install");
    make_file_insecure(&plan.unit_path);
    make_file_insecure(&env_path);

    let report = install_remote_systemd_with(&plan, &|args| Ok(successful_output(&plan, args)))
        .expect("idempotent install secures existing files");

    assert!(!report.unit_written);
    assert!(!report.env_written);
    assert_secured_file(&plan.unit_path, 0o644);
    assert_secured_file(&env_path, 0o600);
}

#[cfg(unix)]
fn make_file_insecure(path: &Path) {
    use nix::unistd::{Gid, Uid, chown};

    if Uid::effective().is_root() {
        chown(
            path,
            Some(Uid::from_raw(65_534)),
            Some(Gid::from_raw(65_534)),
        )
        .expect("set untrusted test ownership");
    }
    fs::set_permissions(path, Permissions::from_mode(0o666))
        .expect("set insecure test permissions");
}

#[cfg(unix)]
fn assert_secured_file(path: &Path, expected_mode: u32) {
    use nix::unistd::{Gid, Uid};

    let metadata = fs::metadata(path).expect("secured file metadata");
    assert_eq!(metadata.uid(), Uid::effective().as_raw());
    assert_eq!(metadata.gid(), Gid::effective().as_raw());
    assert_eq!(metadata.mode() & 0o777, expected_mode);
}

#[cfg(unix)]
#[test]
fn remote_systemd_install_rejects_writable_binary_before_systemctl() {
    let temp = tempdir().expect("temp dir");
    let binary_path = temp.path().join("harness");
    let env_path = temp.path().join("harness.env");
    fs::write(&binary_path, "test binary").expect("write binary");
    fs::set_permissions(&binary_path, Permissions::from_mode(0o775))
        .expect("set writable binary mode");
    let plan = install_plan_with_binary(temp.path(), env_path.clone(), binary_path);
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("invalid binary must be rejected before systemctl")
    };

    let error = install_remote_systemd_with(&plan, &runner)
        .expect_err("group-writable binary must be rejected");

    assert!(error.to_string().contains("group- or world-writable"));
    assert!(!plan.unit_path.exists());
    assert!(!env_path.exists());
}

#[cfg(unix)]
#[test]
fn remote_systemd_install_rejects_replaceable_binary_ancestor() {
    let temp = tempdir().expect("temp dir");
    let writable_parent = temp.path().join("replaceable");
    let binary_path = writable_parent.join("harness");
    let env_path = temp.path().join("harness.env");
    fs::create_dir(&writable_parent).expect("create binary parent");
    fs::write(&binary_path, "test binary").expect("write binary");
    fs::set_permissions(&binary_path, Permissions::from_mode(0o755)).expect("set binary mode");
    fs::set_permissions(&writable_parent, Permissions::from_mode(0o777))
        .expect("make binary parent replaceable");
    let plan = install_plan_with_binary(temp.path(), env_path, binary_path);
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("replaceable binary must be rejected before systemctl")
    };

    let error = install_remote_systemd_with(&plan, &runner)
        .expect_err("replaceable binary ancestor must be rejected");

    assert!(error.to_string().contains("ancestor"));
    assert!(error.to_string().contains("group- or world-writable"));
}

#[cfg(unix)]
#[test]
fn remote_systemd_install_rejects_symlink_binary_before_systemctl() {
    let temp = tempdir().expect("temp dir");
    let target_path = temp.path().join("harness-target");
    let binary_path = temp.path().join("harness-link");
    let env_path = temp.path().join("harness.env");
    fs::write(&target_path, "test binary").expect("write binary target");
    fs::set_permissions(&target_path, Permissions::from_mode(0o755)).expect("set binary mode");
    symlink(&target_path, &binary_path).expect("create binary symlink");
    let plan = install_plan_with_binary(temp.path(), env_path.clone(), binary_path);
    let runner = |_args: &[String]| -> Result<RemoteSystemdCommandOutput, CliError> {
        panic!("symlink binary must be rejected before systemctl")
    };

    let error =
        install_remote_systemd_with(&plan, &runner).expect_err("symlink binary must be rejected");

    assert!(
        error
            .to_string()
            .contains("symbolic link configured binary")
    );
    assert!(!plan.unit_path.exists());
    assert!(!env_path.exists());
}

fn install_plan(root: &Path, env_path: PathBuf) -> RemoteSystemdInstallPlan {
    install_plan_with_binary(root, env_path, trusted_test_executable(root))
}

fn install_plan_with_binary(
    root: &Path,
    env_path: PathBuf,
    binary_path: PathBuf,
) -> RemoteSystemdInstallPlan {
    let args = install_args();
    RemoteSystemdInstallPlan::for_tests(
        &args,
        binary_path,
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

fn successful_output(
    plan: &RemoteSystemdInstallPlan,
    args: &[String],
) -> RemoteSystemdCommandOutput {
    RemoteSystemdCommandOutput {
        exit_code: 0,
        stdout: if args.first().map(String::as_str) == Some("show") {
            effective_install_show_for_tests(plan)
        } else {
            String::new()
        },
        stderr: String::new(),
    }
}
