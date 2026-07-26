use std::path::Path;

use super::args;
use crate::unit::{render_socket_unit, render_unit};

#[test]
fn the_service_requires_its_matching_socket() {
    let service = render_unit(
        "harness-panel",
        Path::new("/usr/bin/harness-panel"),
        &args(),
    )
    .expect("service unit");

    assert!(
        service.contains("Requires=harness-panel.socket\n"),
        "{service}"
    );
    assert!(
        service.contains("After=network-online.target harness-panel.socket\n"),
        "{service}"
    );
    assert!(
        service.contains("Sockets=harness-panel.socket\n"),
        "{service}"
    );
    assert!(service.contains("NonBlocking=true\n"), "{service}");
    assert!(
        service.contains("Environment=HARNESS_PANEL_REQUIRE_SOCKET_ACTIVATION=1\n"),
        "{service}"
    );
}

#[test]
fn the_socket_owns_the_configured_listener() {
    let socket = render_socket_unit(
        "harness-panel",
        "127.0.0.1:8787".parse().expect("listen address"),
    )
    .expect("socket unit");

    assert!(socket.contains("ListenStream=127.0.0.1:8787\n"), "{socket}");
    assert!(socket.contains("Accept=no\n"), "{socket}");
    assert!(
        socket.contains("FileDescriptorName=harness-panel-http\n"),
        "{socket}"
    );
    assert!(socket.contains("ReusePort=false\n"), "{socket}");
    assert!(
        socket.contains("Service=harness-panel.service\n"),
        "{socket}"
    );
    assert!(socket.contains("WantedBy=sockets.target\n"), "{socket}");
}

#[test]
fn the_socket_contains_no_service_command_or_credentials() {
    let socket = render_socket_unit(
        "harness-panel",
        "127.0.0.1:8787".parse().expect("listen address"),
    )
    .expect("socket unit");

    assert!(!socket.contains("LoadCredential="), "{socket}");
    assert!(!socket.contains("ExecStart="), "{socket}");
}

#[test]
fn the_socket_refuses_non_loopback_listeners() {
    for listen in ["0.0.0.0:8787", "192.0.2.1:8787", "[::]:8787"] {
        let error = render_socket_unit("harness-panel", listen.parse().expect("listen address"))
            .expect_err("public listener must be refused");
        assert!(error.to_string().contains("--listen"), "{listen}: {error}");
    }
}

#[test]
fn systemd_units_refuse_an_ephemeral_listener_port() {
    let listen = "127.0.0.1:0".parse().expect("listen address");
    let mut service_args = args();
    service_args.listen = listen;

    let service_error = render_unit(
        "harness-panel",
        Path::new("/usr/bin/harness-panel"),
        &service_args,
    )
    .expect_err("service unit must use a stable port");
    let socket_error = render_socket_unit("harness-panel", listen)
        .expect_err("socket unit must use a stable port");

    assert!(service_error.to_string().contains("non-zero port"));
    assert!(socket_error.to_string().contains("non-zero port"));
}

#[test]
fn the_socket_refuses_an_unusable_unit_name() {
    let listen = "127.0.0.1:8787".parse().expect("listen address");

    assert!(render_socket_unit("../harness-panel", listen).is_err());
}
