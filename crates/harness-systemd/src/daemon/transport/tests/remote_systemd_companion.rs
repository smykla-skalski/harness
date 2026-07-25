//! Install-plan coverage for the companion routing flags.
//!
//! The installer refuses a hand-edited unit, so these flags only reach a
//! deployed daemon through the rendered `ExecStart`. That makes two things
//! this module's job: that both crates accept and reject the same companion
//! values, and that nothing which could end the `ExecStart` line early ever
//! reaches the unit.

use std::path::PathBuf;

use super::super::remote_systemd::RemoteSystemdInstallPlan;
use super::remote_systemd_plan::install_args;

#[test]
fn remote_systemd_plan_renders_companion_routing_flags() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--companion-upstream",
        "http://127.0.0.1:8787",
    ]);
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan");

    assert!(
        plan.unit_contents
            .contains("--companion-upstream http://127.0.0.1:8787"),
        "{}",
        plan.unit_contents
    );
    assert!(
        plan.unit_contents
            .contains("--companion-path-prefix /panel"),
        "{}",
        plan.unit_contents
    );
}

#[test]
fn remote_systemd_plan_accepts_the_upstream_schemes_the_daemon_accepts() {
    for upstream in [
        "http://127.0.0.1:8787",
        "HTTP://127.0.0.1:8787",
        "http://localhost:8787",
        "http://[::1]:8787",
        "http://127.0.0.1:8787/",
    ] {
        let args = install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-upstream",
            upstream,
        ]);

        RemoteSystemdInstallPlan::for_tests(
            &args,
            PathBuf::from("/usr/local/bin/harness"),
            PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
            PathBuf::from("/etc/harness/harness-remote-daemon.env"),
        )
        .unwrap_or_else(|error| {
            panic!("{upstream} must be accepted like the daemon does: {error}")
        });
    }
}

#[test]
fn remote_systemd_plan_omits_companion_flags_when_none_is_configured() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
    ]);
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("systemd install plan");

    assert!(!plan.unit_contents.contains("--companion-"));
}

#[test]
fn remote_systemd_plan_refuses_a_companion_the_daemon_would_reject() {
    for (upstream, prefix) in [
        ("http://198.51.100.9:8787", "/panel"),
        ("http://panel.internal:8787", "/panel"),
        ("https://127.0.0.1:8787", "/panel"),
        ("http://127.0.0.1:8787/panel", "/panel"),
        ("http://user:pass@127.0.0.1:8787", "/panel"),
        ("http://user@localhost:8787", "/panel"),
        // A raw newline would end the ExecStart directive and turn the rest
        // into a unit directive of its own.
        ("http://127.0.0.1:\n8787", "/panel"),
        ("http://127.0.0.1:8787\nExecStartPost=/bin/sh", "/panel"),
        ("http://127.0.0.1 :8787", "/panel"),
        ("http://127.0.0.1:8787", "/v1"),
        ("http://127.0.0.1:8787", "/v1/remote"),
        ("http://127.0.0.1:8787", "/"),
        ("http://127.0.0.1:8787", "panel"),
        ("http://127.0.0.1:8787", "/panel/"),
        ("http://127.0.0.1:8787", "/panel//api"),
        ("http://127.0.0.1:8787", "/pa nel"),
        ("http://127.0.0.1:8787", "/panel?x=1"),
        ("http://127.0.0.1:8787", "/panel#top"),
        ("http://127.0.0.1:8787", "/{panel}"),
        ("http://127.0.0.1:8787", "/panel/*"),
        ("http://127.0.0.1:8787", "/panel\\x"),
    ] {
        let args = install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-upstream",
            upstream,
            "--companion-path-prefix",
            prefix,
        ]);

        RemoteSystemdInstallPlan::for_tests(
            &args,
            PathBuf::from("/usr/local/bin/harness"),
            PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
            PathBuf::from("/etc/harness/harness-remote-daemon.env"),
        )
        .expect_err(&format!("{upstream} with {prefix} must be refused"));
    }
}

/// No rendered unit may contain a value that ends the `ExecStart` line early,
/// whatever earlier validation let through.
#[test]
fn remote_systemd_plan_never_renders_a_companion_value_with_a_control_character() {
    for (label, upstream, prefix) in [
        (
            "companion upstream",
            "http://127.0.0.1:\u{7f}8787",
            "/panel",
        ),
        (
            "companion path prefix",
            "http://127.0.0.1:8787",
            "/pa\u{7f}nel",
        ),
    ] {
        let args = install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-upstream",
            upstream,
            "--companion-path-prefix",
            prefix,
        ]);

        let error = RemoteSystemdInstallPlan::for_tests(
            &args,
            PathBuf::from("/usr/local/bin/harness"),
            PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
            PathBuf::from("/etc/harness/harness-remote-daemon.env"),
        )
        .expect_err(&format!("{label} with a control character must be refused"))
        .to_string();

        assert!(
            error.contains("control characters") || error.contains(label),
            "{label} rejection should name the cause, got {error}"
        );
    }
}

/// One error variant covers every prefix rejection, so its message has to name
/// every rule or an operator cannot tell which one their value broke.
#[test]
fn remote_systemd_prefix_rejection_names_every_rule_it_covers() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-path-prefix",
        "/pa nel",
    ]);

    let error = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect_err("a prefix containing a space must be refused")
    .to_string();

    for rule in [
        "absolute path",
        "trailing slash",
        "empty segment",
        "whitespace, control, or URL-structural character",
        "must not start with /v1",
    ] {
        assert!(error.contains(rule), "message omits {rule}: {error}");
    }
}
