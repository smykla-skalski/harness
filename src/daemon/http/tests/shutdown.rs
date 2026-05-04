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
