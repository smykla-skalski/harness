#[tokio::test]
async fn serve_stops_cleanly_when_shutdown_is_already_requested() {
    let state = super::test_http_state_with_db();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    shutdown_tx.send(true).expect("signal shutdown");

    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        super::super::serve(listener, state, shutdown_rx),
    )
    .await
    .expect("serve should stop promptly")
    .expect("serve should stop cleanly");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn serve_does_not_notify_ready_after_shutdown_is_requested() {
    use std::io::ErrorKind;
    use std::os::unix::net::UnixDatagram;

    let temp = tempfile::tempdir_in("/tmp").expect("short temp dir");
    let socket_path = temp.path().join("notify.sock");
    let receiver = UnixDatagram::bind(&socket_path).expect("bind notification socket");
    receiver
        .set_nonblocking(true)
        .expect("set notification socket nonblocking");
    let state = super::test_http_state_with_db();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let (_shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(true);

    temp_env::async_with_vars(
        [("NOTIFY_SOCKET", Some(socket_path.as_os_str()))],
        super::super::serve(listener, state, shutdown_rx),
    )
    .await
    .expect("serve should stop without notifying readiness");

    let mut message = [0_u8; 32];
    let error = receiver
        .recv(&mut message)
        .expect_err("shutdown server must not send READY");
    assert_eq!(error.kind(), ErrorKind::WouldBlock);
}
