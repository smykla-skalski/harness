use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use futures_util::SinkExt as _;
use tokio::net::TcpListener;
use tokio_tungstenite::accept_hdr_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};

use super::{Attempt, DaemonEventStream, DaemonPairingEvent, header_value};
use crate::config::daemon::resolve;
use crate::daemon_client::{CLIENT_ID_HEADER, DaemonClient, DaemonCredential};
use crate::events::{PanelChange, PanelEvents};
use crate::store::Store;
use crate::store::accounts::AccountIdentity;
use crate::store::pair_links::PairLinkRecord;

fn client_for(endpoint: &str) -> DaemonClient {
    let pin = format!("sha256/{}", STANDARD.encode([9_u8; 32]));
    let config = resolve(endpoint, &pin, "operator", 600).expect("a daemon configuration");
    DaemonClient::new(&config).expect("a daemon client")
}

/// The endpoint may carry a prefix — a daemon behind a reverse proxy — and the
/// socket has to be reached under it like every other route, or a deployment
/// that works over HTTP silently never receives an event.
#[test]
fn the_event_route_keeps_the_endpoint_prefix_and_changes_only_the_scheme() {
    for (endpoint, expected) in [
        (
            "https://harness.example.com",
            "wss://harness.example.com/v1/remote/ws",
        ),
        (
            "https://harness.example.com/harness/",
            "wss://harness.example.com/harness/v1/remote/ws",
        ),
        ("http://127.0.0.1:8443", "ws://127.0.0.1:8443/v1/remote/ws"),
    ] {
        let url = client_for(endpoint)
            .event_socket_url()
            .expect("a websocket url");

        assert_eq!(url.as_str(), expected, "{endpoint}");
    }
}

/// A token carrying a newline would be truncated into a request that
/// authenticates as nobody, and the refusal would land on the far side of a
/// socket with no reader.
#[test]
fn a_credential_that_cannot_be_sent_as_a_header_is_refused() {
    assert!(header_value("Bearer good-token").is_ok());
    assert!(header_value("Bearer bad\r\nX-Injected: yes").is_err());
}

/// The daemon's own frame, with fields the panel does not read. A strict decode
/// would turn each addition on that side into a panel that stops receiving
/// events, which is exactly the failure this stream exists to prevent.
#[test]
fn a_daemon_frame_decodes_without_the_fields_the_panel_ignores() {
    let event: DaemonPairingEvent = serde_json::from_str(
        r#"{
            "change": "claimed",
            "pairing": {
                "pairing_id": "pair-1",
                "state": "active",
                "role": "operator",
                "created_at": "2026-07-26T10:00:00Z",
                "expires_at": "2026-07-26T10:10:00Z",
                "claimed_at": "2026-07-26T10:01:00Z",
                "minted_by": "panel-1",
                "minted_for": {"provider": "github", "subject_id": "4242"},
                "device": {
                    "client_id": "device-1",
                    "display_name": "Ada's laptop",
                    "platform": "macos"
                }
            }
        }"#,
    )
    .expect("a daemon event");

    assert_eq!(event.change, "claimed");
    assert_eq!(event.pairing.pairing_id, "pair-1");
    assert_eq!(
        event
            .pairing
            .device
            .expect("a claimed pairing names its device")
            .display_name,
        "Ada's laptop"
    );
}

/// What the stub daemon was asked for, so a test can prove the panel presented
/// its credential rather than connecting anonymously.
#[derive(Debug, Default)]
struct Seen {
    client_id: Option<String>,
    authorization: Option<String>,
}

/// A daemon that accepts one socket, sends `frames`, and closes.
async fn stub_daemon(frames: Vec<String>) -> (String, Arc<Mutex<Seen>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let address = listener.local_addr().expect("local address");
    let seen = Arc::new(Mutex::new(Seen::default()));
    let recorder = Arc::clone(&seen);

    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let mut socket = accept_hdr_async(stream, |request: &Request, response: Response| {
            let read = |name: &str| {
                request
                    .headers()
                    .get(name)
                    .and_then(|value| value.to_str().ok())
                    .map(str::to_owned)
            };
            let mut noted = recorder.lock().expect("record the handshake");
            noted.client_id = read(CLIENT_ID_HEADER);
            noted.authorization = read("authorization");
            Ok::<_, ErrorResponse>(response)
        })
        .await
        .expect("accept the websocket");

        for frame in frames {
            socket.send(Message::text(frame)).await.expect("send");
        }
        socket.close(None).await.expect("close");
    });

    (format!("http://{address}"), seen)
}

async fn paired_store() -> Store {
    let store = Store::open_in_memory().await.expect("store");
    store
        .store_daemon_credential(
            &DaemonCredential {
                client_id: "panel-1".to_owned(),
                token: "secret-token".to_owned(),
                role: "pairing_broker".to_owned(),
            },
            Utc::now(),
        )
        .await
        .expect("record the credential");
    store
}

fn frame(pairing_id: &str, change: &str) -> String {
    serde_json::json!({
        "change": change,
        "pairing": {
            "pairing_id": pairing_id,
            "state": "active",
            "role": "operator",
            "created_at": "2026-07-26T10:00:00Z",
            "expires_at": "2026-07-26T10:10:00Z",
            "claimed_at": "2026-07-26T10:01:00Z",
        }
    })
    .to_string()
}

/// The whole of the panel's half: it presents its credential, announces that a
/// watcher's picture may be stale the moment the socket is up, and attributes
/// each change to the account it minted the link for.
#[tokio::test]
async fn a_claim_reaches_the_watchers_attributed_to_the_account_it_was_minted_for() {
    let (endpoint, seen) = stub_daemon(vec![frame("pair-1", "claimed")]).await;
    let store = paired_store().await;
    let account = store
        .upsert_account(
            &AccountIdentity {
                provider: "github".to_owned(),
                subject_id: "4242".to_owned(),
                login: "ada".to_owned(),
                display_name: "Ada".to_owned(),
                avatar_url: None,
            },
            Utc::now(),
        )
        .await
        .expect("an account to attribute the link to");
    store
        .record_pair_link(&PairLinkRecord {
            id: "pair-1".to_owned(),
            account_id: account.id.clone(),
            role: "operator".to_owned(),
            created_at: Utc::now(),
            expires_at: Utc::now(),
        })
        .await
        .expect("record the link");
    let events = PanelEvents::new();
    let mut watcher = events.watch();

    let stream = DaemonEventStream::new(client_for(&endpoint), store, events);
    let attempt = stream.attempt().await.expect("one connection");

    assert!(matches!(attempt, Attempt::Closed { .. }));
    assert_eq!(
        watcher.recv().await.expect("the socket coming up"),
        PanelChange::Resynced,
        "a socket that has just come up replayed nothing, so watchers must re-read"
    );
    let PanelChange::Pairing(changed) = watcher.recv().await.expect("the claim") else {
        panic!("expected the claim to arrive as a pairing change");
    };
    assert_eq!(changed.change, "claimed");
    assert_eq!(changed.pairing.pairing_id, "pair-1");
    assert_eq!(changed.account_id.as_ref(), Some(&account.id));

    let recorded = seen.lock().expect("read the handshake");
    assert_eq!(recorded.client_id.as_deref(), Some("panel-1"));
    assert_eq!(
        recorded.authorization.as_deref(),
        Some("Bearer secret-token")
    );
}

/// A pairing the panel has no record of still reaches the watchers, without an
/// account. Only the owner is shown it, and inventing an attribution here would
/// be the one way somebody else's device could land on a person's page.
#[tokio::test]
async fn a_pairing_the_panel_never_recorded_arrives_unattributed() {
    let (endpoint, _) = stub_daemon(vec![frame("pair-elsewhere", "minted")]).await;
    let events = PanelEvents::new();
    let mut watcher = events.watch();

    let stream = DaemonEventStream::new(client_for(&endpoint), paired_store().await, events);
    stream.attempt().await.expect("one connection");

    assert_eq!(watcher.recv().await.expect("resync"), PanelChange::Resynced);
    let PanelChange::Pairing(changed) = watcher.recv().await.expect("the mint") else {
        panic!("expected the mint to arrive as a pairing change");
    };
    assert_eq!(changed.account_id, None);
}

/// A frame the panel cannot read is the daemon's business, not this socket's.
/// Dropping the connection over one would cost every change that followed it.
#[tokio::test]
async fn an_unreadable_frame_does_not_cost_the_ones_after_it() {
    let (endpoint, _) = stub_daemon(vec![
        "not json at all".to_owned(),
        frame("pair-2", "revoked"),
    ])
    .await;
    let events = PanelEvents::new();
    let mut watcher = events.watch();

    let stream = DaemonEventStream::new(client_for(&endpoint), paired_store().await, events);
    stream.attempt().await.expect("one connection");

    assert_eq!(watcher.recv().await.expect("resync"), PanelChange::Resynced);
    let PanelChange::Pairing(changed) = watcher.recv().await.expect("the revoke") else {
        panic!("expected the revoke to arrive as a pairing change");
    };
    assert_eq!(changed.pairing.pairing_id, "pair-2");
}

/// A panel nobody has paired yet has nothing to authenticate with. That is the
/// state a fresh install is in, so it must read as waiting rather than as a
/// failure worth retrying hard or logging on every attempt.
#[tokio::test]
async fn an_unpaired_panel_waits_instead_of_dialling() {
    let events = PanelEvents::new();
    let mut watcher = events.watch();
    let store = Store::open_in_memory().await.expect("store");

    let stream = DaemonEventStream::new(client_for("http://127.0.0.1:1"), store, events);

    assert!(matches!(
        stream
            .attempt()
            .await
            .expect("no credential is not a failure"),
        Attempt::Unpaired
    ));
    assert!(
        watcher.try_recv().is_err(),
        "nothing happened, so nothing should have been announced"
    );
}
