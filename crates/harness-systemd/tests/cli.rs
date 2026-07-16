use assert_cmd::cargo::cargo_bin;
use std::process::Command;

#[test]
fn direct_cli_exposes_only_lifecycle_verbs() {
    let output = Command::new(cargo_bin("harness-systemd"))
        .arg("--help")
        .output()
        .expect("run harness-systemd help");
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 help");
    for command in [
        "install",
        "upgrade",
        "rollback",
        "recover",
        "uninstall",
        "status",
    ] {
        assert!(stdout.contains(command), "help omitted {command}: {stdout}");
    }
    for legacy in [
        "install-systemd",
        "upgrade-systemd",
        "rollback-systemd",
        "recover-systemd",
        "uninstall-systemd",
    ] {
        assert!(!stdout.contains(legacy), "help retained {legacy}: {stdout}");
    }
}

#[test]
fn every_direct_lifecycle_subcommand_parses_its_help() {
    for command in [
        "install",
        "upgrade",
        "rollback",
        "recover",
        "uninstall",
        "status",
    ] {
        let output = Command::new(cargo_bin("harness-systemd"))
            .args([command, "--help"])
            .output()
            .expect("run lifecycle subcommand help");
        assert!(
            output.status.success(),
            "{command} help failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn upgrade_and_rollback_dry_runs_use_direct_command_names() {
    for command in ["upgrade", "rollback"] {
        let output = Command::new(cargo_bin("harness-systemd"))
            .args([command, "--unit", "harness-remote", "--dry-run", "--json"])
            .output()
            .expect("run lifecycle dry-run");
        assert!(
            output.status.success(),
            "{command} dry-run failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn install_dry_run_renders_standalone_daemon_exec_start() {
    let output = Command::new(cargo_bin("harness-systemd"))
        .args([
            "install",
            "--unit",
            "harness-remote",
            "--binary-path",
            "/usr/local/bin/harness-daemon",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--dry-run",
            "--json",
        ])
        .output()
        .expect("run install dry-run");
    assert!(
        output.status.success(),
        "install dry-run failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let response: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("decode install response");
    assert_eq!(response["unit"], "harness-remote");
    assert_eq!(response["dry_run"], true);
}
