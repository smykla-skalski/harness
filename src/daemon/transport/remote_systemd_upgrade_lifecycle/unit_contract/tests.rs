use std::cell::RefCell;
use std::fs::Permissions;
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::fs::symlink;
use std::time::Duration;

use tempfile::tempdir_in;

use super::super::super::remote_systemd_inhibitor::{inhibitor_path, install_inhibitor};
use super::super::model::RemoteSystemdHealthReport;
use super::super::systemd::start_and_verify;
use super::*;

#[path = "tests/environment.rs"]
mod environment;
#[path = "tests/mount_namespace.rs"]
mod mount_namespace;
#[path = "tests/permit.rs"]
mod permit;

struct ContractFixture {
    _temp: tempfile::TempDir,
    plan: RemoteSystemdOperationPlan,
}

impl ContractFixture {
    fn new() -> Self {
        let temp = tempdir_in(env!("CARGO_MANIFEST_DIR")).expect("trusted tempdir");
        let binary = temp.path().join("harness");
        let unit_path = temp.path().join("harness-remote.service");
        let environment_path = temp.path().join("harness-remote.env");
        fs::write(&binary, "test binary").expect("write binary");
        fs::set_permissions(&binary, Permissions::from_mode(0o755)).expect("chmod binary");
        fs::write(&environment_path, "RUST_LOG=harness=info\n").expect("write environment");
        fs::write(
            &unit_path,
            format!(
                "[Service]\nType=notify\nNotifyAccess=main\nTimeoutStartSec=20min\nKillMode=control-group\nEnvironmentFile={}\nEnvironment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote\nEnvironment=XDG_DATA_HOME=%S/harness-remote\nEnvironment=HARNESS_DAEMON_OWNERSHIP=external\nExecStart={} remote serve --domain daemon.example.com\nDynamicUser=yes\nStateDirectory=harness-remote\nStateDirectoryMode=0700\n",
                environment_path.display(),
                binary.display()
            ),
        )
        .expect("write unit");
        let plan = RemoteSystemdOperationPlan {
            unit: "harness-remote".to_string(),
            binary_path: binary,
            unit_path,
            environment_path,
            state_path: temp.path().join("state"),
            store_path: temp.path().join("store"),
            controller_path: temp.path().join("controller"),
            readiness_timeout: Duration::from_secs(1),
            stabilization_window: Duration::ZERO,
        };
        Self { _temp: temp, plan }
    }

    fn effective_output(&self) -> String {
        let output = format!(
            "FragmentPath={}\nDropInPaths=\nUser=\nGroup=\nDynamicUser=yes\nStateDirectory=harness-remote\nStateDirectoryMode=0700\nType=notify\nNotifyAccess=main\nTimeoutStartUSec=20min\nKillMode=control-group\nEnvironment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote XDG_DATA_HOME=%S/harness-remote HARNESS_DAEMON_OWNERSHIP=external\nEnvironmentFiles={} (ignore_errors=no)\nExecStart={{ path={} ; argv[]={} remote serve --domain daemon.example.com ; ignore_errors=no ; }}\nExecStartPre=\nExecStartPost=\nExecCondition=\nExecReload=\nExecStop=\nExecStopPost=\nUnsetEnvironment=\n",
            self.plan.unit_path.display(),
            self.plan.environment_path.display(),
            self.plan.binary_path.display(),
            self.plan.binary_path.display()
        );
        output
            .replace("%S/harness-remote", "/var/lib/harness-remote")
            .replacen(
            "User=\nGroup=\nDynamicUser=yes\n",
            "User=harness-remote\nGroup=harness-remote\nDynamicUser=yes\nUID=[not set]\nGID=[not set]\nMainPID=0\nNeedDaemonReload=no\n",
            1,
        )
    }

    fn validate_with(&self, stdout: String) -> Result<(), CliError> {
        validate_managed_unit_contract(&self.plan, &|_| {
            Ok(RemoteSystemdCommandOutput {
                exit_code: 0,
                stdout: stdout.clone(),
                stderr: String::new(),
            })
        })
    }

    fn rewrite_unit(&self, replace: impl FnOnce(String) -> String) {
        let contents = fs::read_to_string(&self.plan.unit_path).expect("read unit");
        fs::write(&self.plan.unit_path, replace(contents)).expect("rewrite unit");
    }
}

#[test]
fn complete_dynamic_user_contract_is_accepted() {
    let fixture = ContractFixture::new();
    fixture
        .validate_with(fixture.effective_output())
        .expect("managed unit contract");
}

#[test]
fn inhibited_contract_accepts_only_the_exact_managed_drop_in() {
    let fixture = ContractFixture::new();
    install_inhibitor(&fixture.plan.unit_path).expect("install exact inhibitor");
    let inhibitor = inhibitor_path(&fixture.plan.unit_path).expect("inhibitor path");
    let output = fixture.effective_output().replace(
        "DropInPaths=",
        &format!("DropInPaths={}", inhibitor.display()),
    );
    validate_inhibited_managed_unit_contract(&fixture.plan, &|_| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: output.clone(),
            stderr: String::new(),
        })
    })
    .expect("exact inhibited contract");

    let drifted = output.replace(
        &inhibitor.display().to_string(),
        &format!(
            "{} /etc/systemd/system/late-override.conf",
            inhibitor.display()
        ),
    );
    let error = validate_inhibited_managed_unit_contract(&fixture.plan, &|_| {
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: drifted.clone(),
            stderr: String::new(),
        })
    })
    .expect_err("later effective drop-in must fail closed");
    assert!(error.to_string().contains("unexpected drop-ins"));
}

#[test]
fn legacy_simple_runtime_contract_remains_accepted() {
    let fixture = ContractFixture::new();
    fixture.rewrite_unit(|contents| {
        contents.replace(
            "Type=notify\nNotifyAccess=main\nTimeoutStartSec=20min\n",
            "Type=simple\n",
        )
    });
    let output = fixture
        .effective_output()
        .replace("Type=notify", "Type=simple")
        .replace("NotifyAccess=main", "NotifyAccess=all")
        .replace("TimeoutStartUSec=20min", "TimeoutStartUSec=1min 30s");

    fixture
        .validate_with(output)
        .expect("legacy simple contract must remain rollback-compatible");
}

#[test]
fn source_type_must_be_exactly_one_supported_value() {
    let missing = ContractFixture::new();
    missing.rewrite_unit(|contents| contents.replace("Type=notify\n", ""));
    let missing_error = validate_managed_unit_contract(&missing.plan, &|_| {
        panic!("source rejection must happen before effective inspection")
    })
    .expect_err("missing Type must fail closed");
    assert!(missing_error.to_string().contains("exactly one Type"));

    let duplicate = ContractFixture::new();
    duplicate.rewrite_unit(|contents| contents.replace("Type=notify", "Type=simple\nType=notify"));
    let duplicate_error = validate_managed_unit_contract(&duplicate.plan, &|_| {
        panic!("source rejection must happen before effective inspection")
    })
    .expect_err("duplicate Type must fail closed");
    assert!(duplicate_error.to_string().contains("exactly one Type"));

    let unsupported = ContractFixture::new();
    unsupported.rewrite_unit(|contents| contents.replace("Type=notify", "Type=forking"));
    let unsupported_error = validate_managed_unit_contract(&unsupported.plan, &|_| {
        panic!("source rejection must happen before effective inspection")
    })
    .expect_err("unsupported Type must fail closed");
    assert!(unsupported_error.to_string().contains("simple or notify"));
}

#[test]
fn notify_source_requires_managed_readiness_contract() {
    for (directive, expected) in [
        ("NotifyAccess=main\n", "NotifyAccess=main"),
        ("TimeoutStartSec=20min\n", "TimeoutStartSec=20min"),
    ] {
        let fixture = ContractFixture::new();
        fixture.rewrite_unit(|contents| contents.replace(directive, ""));
        let error = validate_managed_unit_contract(&fixture.plan, &|_| {
            panic!("source rejection must happen before effective inspection")
        })
        .expect_err("incomplete notify readiness must fail closed");
        assert!(error.to_string().contains(expected));
    }
}

#[test]
fn effective_type_and_notify_readiness_must_match_source() {
    let type_fixture = ContractFixture::new();
    let type_error = type_fixture
        .validate_with(
            type_fixture
                .effective_output()
                .replace("Type=notify", "Type=simple"),
        )
        .expect_err("source/effective Type mismatch must fail closed");
    assert!(type_error.to_string().contains("must agree"));

    let duplicate_fixture = ContractFixture::new();
    let duplicate_error = duplicate_fixture
        .validate_with(
            duplicate_fixture
                .effective_output()
                .replace("Type=notify", "Type=notify\nType=notify"),
        )
        .expect_err("duplicate effective Type must fail closed");
    assert!(
        duplicate_error
            .to_string()
            .contains("exactly one Type property")
    );

    for (property, replacement) in [
        ("NotifyAccess=main", "NotifyAccess=all"),
        ("TimeoutStartUSec=20min", "TimeoutStartUSec=30s"),
    ] {
        let fixture = ContractFixture::new();
        let error = fixture
            .validate_with(fixture.effective_output().replace(property, replacement))
            .expect_err("effective notify readiness drift must fail closed");
        assert!(error.to_string().contains(property));
    }
}

#[test]
fn loaded_exec_start_must_match_managed_binary_and_command_prefix() {
    let path_fixture = ContractFixture::new();
    let path_field = format!("path={}", path_fixture.plan.binary_path.display());
    let path_error = path_fixture
        .validate_with(
            path_fixture
                .effective_output()
                .replace(&path_field, "path=/tmp/stale-harness"),
        )
        .expect_err("stale loaded binary must fail closed");
    assert!(path_error.to_string().contains("ExecStart must run"));

    let argv_fixture = ContractFixture::new();
    let argv_error = argv_fixture
        .validate_with(
            argv_fixture
                .effective_output()
                .replace(" remote serve", " remote shell"),
        )
        .expect_err("stale loaded command must fail closed");
    assert!(argv_error.to_string().contains("ExecStart must run"));
}

#[test]
fn effective_exec_start_parser_accepts_metadata_and_rejects_multiple_records() {
    let (path, arguments) = effective::parse_exec_start_for_tests(
        "{ path=/usr/local/bin/harness-daemon ; argv[]=/usr/local/bin/harness-daemon remote serve --domain daemon.example.com ; ignore_errors=no ; pid=42 ; }",
    )
    .expect("parse systemctl ExecStart serialization");
    assert_eq!(path, "/usr/local/bin/harness-daemon");
    assert_eq!(
        arguments,
        [
            "/usr/local/bin/harness-daemon",
            "remote",
            "serve",
            "--domain",
            "daemon.example.com"
        ]
    );

    effective::parse_exec_start_for_tests(
        "{ path=/bin/one ; argv[]=/bin/one remote serve ; } { path=/bin/two ; argv[]=/bin/two remote serve ; }",
    )
    .expect_err("multiple effective command records must fail closed");
}

#[test]
fn start_revalidates_contract_before_any_systemd_mutation() {
    let fixture = ContractFixture::new();
    fixture.rewrite_unit(|contents| contents.replace("Type=notify", "Type=forking"));
    let commands = RefCell::new(Vec::<Vec<String>>::new());
    let run = |args: &[String]| {
        commands.borrow_mut().push(args.to_vec());
        Ok(RemoteSystemdCommandOutput {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    };

    let error = start_and_verify(&fixture.plan, "expected-sha", &run, &|_, expected, _| {
        Ok(RemoteSystemdHealthReport {
            status: "ready".to_string(),
            attempts: 1,
            main_pid: 1,
            n_restarts: 0,
            active_state: "active".to_string(),
            sub_state: "running".to_string(),
            observed_sha256: expected.to_string(),
        })
    })
    .expect_err("start must fail closed on managed unit drift");

    assert!(error.to_string().contains("simple or notify"));
    assert!(commands.borrow().is_empty());
}

#[test]
fn source_privileged_auxiliary_is_rejected_before_systemctl() {
    let fixture = ContractFixture::new();
    fixture.rewrite_unit(|contents| {
        contents.replace(
            "ExecStart=",
            "ExecStartPre=+/usr/bin/install /tmp/payload /usr/local/bin/payload\nExecStart=",
        )
    });

    let error = validate_managed_unit_contract(&fixture.plan, &|_| {
        panic!("source rejection must happen before effective inspection")
    })
    .expect_err("privileged auxiliary must fail closed");

    assert!(
        error
            .to_string()
            .contains("privileged auxiliary ExecStartPre")
    );
}

#[test]
fn effective_identity_and_auxiliaries_are_rejected() {
    let root_fixture = ContractFixture::new();
    let root_output = root_fixture
        .effective_output()
        .replace("User=harness-remote\n", "User=root\n");
    let root_error = root_fixture
        .validate_with(root_output)
        .expect_err("effective root identity must fail closed");
    assert!(
        root_error
            .to_string()
            .contains("must be nonempty and unprivileged")
    );

    let exec_fixture = ContractFixture::new();
    let exec_output = exec_fixture
        .effective_output()
        .replace("ExecStartPre=\n", "ExecStartPre={ path=/bin/true ; }\n");
    let exec_error = exec_fixture
        .validate_with(exec_output)
        .expect_err("effective auxiliary must fail closed");
    assert!(
        exec_error
            .to_string()
            .contains("privileged auxiliary ExecStartPre")
    );
}

#[test]
fn writable_managed_file_is_rejected_before_systemctl() {
    let fixture = ContractFixture::new();
    fs::set_permissions(
        &fixture.plan.environment_path,
        Permissions::from_mode(0o666),
    )
    .expect("make environment writable");

    let error = validate_managed_unit_contract(&fixture.plan, &|_| {
        panic!("mode rejection must happen before effective inspection")
    })
    .expect_err("writable environment must fail closed");

    assert!(
        error
            .to_string()
            .contains("must not be group- or world-writable")
    );
}

#[test]
fn replaceable_or_symlinked_managed_file_ancestors_are_rejected() {
    let writable_fixture = ContractFixture::new();
    let writable_parent = writable_fixture
        .plan
        .binary_path
        .parent()
        .expect("fixture parent")
        .join("writable-bin");
    fs::create_dir(&writable_parent).expect("create writable ancestor");
    fs::set_permissions(&writable_parent, Permissions::from_mode(0o777))
        .expect("make ancestor writable");
    let writable_binary = writable_parent.join("harness");
    fs::write(&writable_binary, "binary").expect("write binary under writable ancestor");
    fs::set_permissions(&writable_binary, Permissions::from_mode(0o755))
        .expect("make binary executable");
    let mut writable_plan = writable_fixture.plan.clone();
    writable_plan.binary_path = writable_binary;
    let writable_error = validate_managed_unit_contract(&writable_plan, &|_| {
        panic!("ancestor rejection must happen before effective inspection")
    })
    .expect_err("writable ancestor must fail closed");
    assert!(writable_error.to_string().contains("ancestor"));
    assert!(writable_error.to_string().contains("world-writable"));

    let symlink_fixture = ContractFixture::new();
    let parent = symlink_fixture
        .plan
        .binary_path
        .parent()
        .expect("fixture parent");
    let real_parent = parent.join("real-bin");
    let linked_parent = parent.join("linked-bin");
    fs::create_dir(&real_parent).expect("create real ancestor");
    let linked_binary = real_parent.join("harness");
    fs::write(&linked_binary, "binary").expect("write binary under linked ancestor");
    fs::set_permissions(&linked_binary, Permissions::from_mode(0o755))
        .expect("make linked binary executable");
    symlink(&real_parent, &linked_parent).expect("link ancestor");
    let mut symlink_plan = symlink_fixture.plan.clone();
    symlink_plan.binary_path = linked_parent.join("harness");
    let symlink_error = validate_managed_unit_contract(&symlink_plan, &|_| {
        panic!("ancestor rejection must happen before effective inspection")
    })
    .expect_err("symlink ancestor must fail closed");
    assert!(symlink_error.to_string().contains("real directory"));
}
