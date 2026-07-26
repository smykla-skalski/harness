//! Install-plan coverage for the companion routing flags.
//!
//! The installer refuses a hand-edited unit, so these flags only reach a
//! deployed daemon through the rendered `ExecStart`. That makes two things
//! this module's job: that both crates accept and reject the same companion
//! values, and that nothing which could end the `ExecStart` line early ever
//! reaches the unit.

use std::path::PathBuf;

use clap::Parser;

use super::super::remote_systemd::DaemonRemoteSystemdInstallArgs;
use super::super::remote_systemd::RemoteSystemdInstallPlan;
use super::remote_systemd_plan::install_args;

const COMPANION_TOKEN_SOURCE: &str = "/etc/harness/companion-auth-token";
const COMPANION_RUNTIME_TOKEN_ARGUMENT: &str =
    "--companion-auth-token-file %d/companion-auth-token";

#[test]
fn remote_systemd_plan_renders_companion_routing_and_credential() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        COMPANION_TOKEN_SOURCE,
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
    assert!(
        plan.unit_contents
            .contains("LoadCredential=companion-auth-token:/etc/harness/companion-auth-token"),
        "{}",
        plan.unit_contents
    );
    assert_eq!(
        plan.unit_contents
            .matches(COMPANION_RUNTIME_TOKEN_ARGUMENT)
            .count(),
        1,
        "credential path must use one expandable systemd %d specifier: {}",
        plan.unit_contents
    );
    assert!(!plan.unit_contents.contains("%%d/companion-auth-token"));
    for directive in [
        "Requires=harness-panel.socket",
        "BindsTo=harness-panel.socket",
        "After=network-online.target harness-panel.socket",
        "Sockets=harness-panel.socket",
        "NonBlocking=true",
        "--companion-systemd-socket-activated",
    ] {
        assert!(
            plan.unit_contents.contains(directive),
            "{directive}: {}",
            plan.unit_contents
        );
    }
}

#[test]
fn remote_systemd_plan_accepts_the_upstream_schemes_the_daemon_accepts() {
    for upstream in [
        "http://127.0.0.1:8787",
        "HTTP://127.0.0.1:8787",
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
            "--companion-auth-token-file",
            COMPANION_TOKEN_SOURCE,
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
    assert!(!plan.unit_contents.contains("LoadCredential="));
    assert!(!plan.unit_contents.contains("harness-panel.socket"));
}

#[test]
fn companion_upstream_and_auth_token_file_are_required_together() {
    assert!(
        try_install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-upstream",
            "http://127.0.0.1:8787",
        ])
        .is_err()
    );
    assert!(
        try_install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-auth-token-file",
            COMPANION_TOKEN_SOURCE,
        ])
        .is_err()
    );
    assert!(
        try_install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-panel-socket-unit",
            "harness-panel.socket",
        ])
        .is_err()
    );
}

#[test]
fn custom_companion_socket_unit_is_rendered_and_validated() {
    let args = install_args([
        "test",
        "--domain",
        "daemon.example.com",
        "--acme-email",
        "ops@example.com",
        "--companion-upstream",
        "http://127.0.0.1:8787",
        "--companion-auth-token-file",
        COMPANION_TOKEN_SOURCE,
        "--companion-panel-socket-unit",
        "custom-panel.socket",
    ]);
    let plan = RemoteSystemdInstallPlan::for_tests(
        &args,
        PathBuf::from("/usr/local/bin/harness"),
        PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
        PathBuf::from("/etc/harness/harness-remote-daemon.env"),
    )
    .expect("custom panel socket unit");

    for directive in [
        "Requires=",
        "BindsTo=",
        "After=network-online.target ",
        "Sockets=",
    ] {
        assert!(
            plan.unit_contents
                .contains(&format!("{directive}custom-panel.socket"))
        );
    }

    for socket in [
        "panel",
        ".socket",
        "../panel.socket",
        "panel.service",
        "panel%h.socket",
        "panel.socket\nBindsTo=attacker.socket",
    ] {
        let mut invalid = args.clone();
        invalid.serve.companion_panel_socket_unit = Some(socket.to_string());
        RemoteSystemdInstallPlan::for_tests(
            &invalid,
            PathBuf::from("/usr/local/bin/harness"),
            PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
            PathBuf::from("/etc/harness/harness-remote-daemon.env"),
        )
        .expect_err(&format!("invalid socket unit must be refused: {socket}"));
    }
}

#[test]
fn remote_systemd_plan_rejects_unsafe_companion_credential_sources() {
    for source in [
        "companion-auth-token",
        "/etc/harness/./companion-auth-token",
        "/etc/harness/../companion-auth-token",
        "/etc/harness/companion auth token",
        "/etc/harness/companion%h-token",
        "/etc/harness/companion\\",
        "/etc/harness/companion\"token",
        "/etc/harness/companion'token",
        "/var/lib/private/harness-remote-daemon/companion-auth-token",
        "/var/lib/harness-remote-daemon/companion-auth-token",
    ] {
        let args = install_args([
            "test",
            "--domain",
            "daemon.example.com",
            "--acme-email",
            "ops@example.com",
            "--companion-upstream",
            "http://127.0.0.1:8787",
            "--companion-auth-token-file",
            source,
        ]);

        let error = RemoteSystemdInstallPlan::for_tests(
            &args,
            PathBuf::from("/usr/local/bin/harness"),
            PathBuf::from("/etc/systemd/system/harness-remote-daemon.service"),
            PathBuf::from("/etc/harness/harness-remote-daemon.env"),
        )
        .expect_err(&format!(
            "unsafe credential source must be refused: {source}"
        ))
        .to_string();

        assert!(
            error.contains("systemd companion credential source path"),
            "{source}: {error}"
        );
    }
}

#[test]
fn remote_systemd_plan_refuses_a_companion_the_daemon_would_reject() {
    for (upstream, prefix) in [
        ("http://198.51.100.9:8787", "/panel"),
        ("http://panel.internal:8787", "/panel"),
        ("http://localhost:8787", "/panel"),
        ("https://127.0.0.1:8787", "/panel"),
        ("http://127.0.0.1:8787/panel", "/panel"),
        ("http://user:pass@127.0.0.1:8787", "/panel"),
        ("http://user@localhost:8787", "/panel"),
        ("http://127.0.0.1:", "/panel"),
        ("http://127.0.0.1:not-a-port", "/panel"),
        ("http://127.0.0.1:0", "/panel"),
        ("http://127.0.0.1:65536", "/panel"),
        ("http://[::1]:", "/panel"),
        ("http://[::1]:not-a-port", "/panel"),
        ("http://[::1]:0", "/panel"),
        ("http://[::1]:65536", "/panel"),
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
        ("http://127.0.0.1:8787", "/panel/./api"),
        ("http://127.0.0.1:8787", "/panel/../api"),
        ("http://127.0.0.1:8787", "/."),
        ("http://127.0.0.1:8787", "/.."),
        ("http://127.0.0.1:8787", "/%2e"),
        ("http://127.0.0.1:8787", "/.%2E"),
        ("http://127.0.0.1:8787", "/%2e."),
        ("http://127.0.0.1:8787", "/%2E%2e"),
        ("http://127.0.0.1:8787", "/panel/%2e/api"),
        ("http://127.0.0.1:8787", "/panel/.%2E/api"),
        ("http://127.0.0.1:8787", "/panel/%2e./api"),
        ("http://127.0.0.1:8787", "/panel/%2E%2e/api"),
        ("http://127.0.0.1:8787", "/pa nel"),
        ("http://127.0.0.1:8787", "/panel?x=1"),
        ("http://127.0.0.1:8787", "/panel#top"),
        ("http://127.0.0.1:8787", "/{panel}"),
        ("http://127.0.0.1:8787", "/panel/*"),
        ("http://127.0.0.1:8787", "/:panel"),
        ("http://127.0.0.1:8787", "/panel/:api"),
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
            "--companion-auth-token-file",
            COMPANION_TOKEN_SOURCE,
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
            "--companion-auth-token-file",
            COMPANION_TOKEN_SOURCE,
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
        "--companion-auth-token-file",
        COMPANION_TOKEN_SOURCE,
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
        "empty, '.', or '..' URL segment",
        "whitespace, control, or URL-structural character",
        "must not start with /v1",
    ] {
        assert!(error.contains(rule), "message omits {rule}: {error}");
    }
}

fn try_install_args<const N: usize>(
    args: [&str; N],
) -> Result<DaemonRemoteSystemdInstallArgs, clap::Error> {
    #[derive(Debug, Parser)]
    struct Harness {
        #[command(flatten)]
        args: DaemonRemoteSystemdInstallArgs,
    }

    Harness::try_parse_from(args).map(|harness| harness.args)
}
