#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::process::Command;

#[test]
fn lifecycle_routes_delegate_raw_arguments_to_harness_systemd() {
    let temporary = tempfile::tempdir().expect("temporary worker directory");
    let worker = temporary.path().join("harness-systemd");
    let capture = temporary.path().join("arguments");
    let script = format!(
        "#!/bin/sh\n\
         if [ \"${{1:-}}\" = \"--version\" ]; then\n\
           printf 'harness-systemd {}\\n'\n\
           exit 0\n\
         fi\n\
         printf '%s\\n' \"$@\" > \"$HARNESS_SYSTEMD_CAPTURE\"\n\
         exit 23\n",
        env!("CARGO_PKG_VERSION")
    );
    fs::write(&worker, script).expect("write fake harness-systemd");
    fs::set_permissions(&worker, fs::Permissions::from_mode(0o755))
        .expect("make fake harness-systemd executable");

    let cases = [
        ("install-systemd", "install"),
        ("upgrade-systemd", "upgrade"),
        ("rollback-systemd", "rollback"),
        ("recover-systemd", "recover"),
        ("uninstall-systemd", "uninstall"),
        ("status", "status"),
    ];
    for (compatibility, direct) in cases {
        let status = Command::new(assert_cmd::cargo::cargo_bin("harness-daemon"))
            .args([
                "--delay",
                "0",
                "remote",
                compatibility,
                "--unit",
                "harness-remote",
                "--json",
            ])
            .env(harness_command::WORKER_DIR_ENV, temporary.path())
            .env("HARNESS_SYSTEMD_CAPTURE", &capture)
            .status()
            .expect("run harness-daemon compatibility route");
        assert_eq!(status.code(), Some(23));
        assert_eq!(
            fs::read_to_string(&capture).expect("read delegated arguments"),
            format!("{direct}\n--unit\nharness-remote\n--json\n")
        );
    }

    let status = Command::new(assert_cmd::cargo::cargo_bin("harness-daemon"))
        .args([
            "remote",
            "--systemd-unit",
            "ignored-runtime-state",
            "status",
            "--unit",
            "harness-remote",
            "--json",
        ])
        .env(harness_command::WORKER_DIR_ENV, temporary.path())
        .env("HARNESS_SYSTEMD_CAPTURE", &capture)
        .status()
        .expect("run compatibility route with daemon-only global");
    assert_eq!(status.code(), Some(23));
    assert_eq!(
        fs::read_to_string(&capture).expect("read delegated arguments"),
        "status\n--unit\nharness-remote\n--json\n"
    );
}
