//! The websocket a signed-in browser holds open.
//!
//! One socket per open page, carrying whatever the panel learns without being
//! asked. It is read-only: a browser with something to change has the routes
//! that change it, and answering here would be a second way to reach them
//! wearing none of their checks.
//!
//! Nothing is replayed on connect. The page reads the pairing list over HTTP,
//! which is the request that answers what is true now, and this only says when
//! that answer has stopped being true.

use std::time::Duration;

use axum::body::Bytes;
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{State, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Serialize;
use tokio::sync::broadcast::Receiver;
use tokio::sync::broadcast::error::RecvError;
use tokio::time::interval;

use super::PanelState;
use super::auth::origin_matches;
use super::pairings::{PanelPairing, visible_to};
use super::session::{Viewer, require_viewer};
use crate::error::ApiError;
use crate::events::{PairingChanged, PanelChange};

/// How often the panel pings an idle socket.
///
/// Something in the middle — the daemon that fronts this, or whatever the reader
/// is behind — will drop a connection that has carried nothing for long enough,
/// and a page whose socket died quietly is a page that stops updating without
/// saying so. The browser answers each ping itself, so this costs a frame a
/// minute and keeps the path warm.
const PING_INTERVAL: Duration = Duration::from_secs(30);

/// Open the socket for the signed-in person.
///
/// # Errors
/// Returns [`ApiError::Forbidden`] when the request did not come from the panel
/// origin, [`ApiError::Unauthenticated`] when nobody is signed in, and
/// [`ApiError::Internal`] when the session store cannot be read.
pub async fn stream(
    State(state): State<PanelState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    // A `SameSite` cookie is withheld from a cross-site handshake, so this is
    // belt and braces — but it is the same guard the state-changing routes
    // carry, and what this socket streams is the list of a person's devices.
    if !origin_matches(&headers, &state.config.public_origin) {
        return Err(ApiError::Forbidden(
            "the event socket must be opened from the panel origin",
        ));
    }
    let viewer = require_viewer(&state, &headers).await?;
    // Subscribed before the upgrade, so what this socket may carry is fixed by
    // the session that opened it. Resolving the viewer again per change would
    // let one that expired mid-connection decide nothing, and one that gained
    // ownership decide more than it had when it connected.
    let changes = state.events.watch();
    Ok(ws.on_upgrade(move |socket| serve(socket, changes, viewer)))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "the three-arm tokio::select! expansion costs 3 an arm, measured: 11 with all three and 8 with two. The structural remainder is the loop and one early return per arm, which is 4"
)]
async fn serve(mut socket: WebSocket, mut changes: Receiver<PanelChange>, viewer: Viewer) {
    let mut heartbeat = interval(PING_INTERVAL);
    // The first tick fires immediately and would ping a socket opened this
    // instant, which proves nothing and only costs a frame.
    heartbeat.tick().await;

    loop {
        tokio::select! {
            incoming = socket.recv() => {
                if !still_attached(incoming.as_ref()) {
                    return;
                }
            }
            change = changes.recv() => {
                if !relay(&mut socket, change, &viewer).await {
                    return;
                }
            }
            _ = heartbeat.tick() => {
                if socket.send(Message::Ping(Bytes::new())).await.is_err() {
                    return;
                }
            }
        }
    }
}

/// Whether the browser is still on the other end.
///
/// What it sent is discarded rather than answered: this socket is one way, and a
/// browser with something to ask has the routes that answer. Reading it at all is
/// what makes a close frame end the connection promptly instead of on the next
/// ping.
fn still_attached(incoming: Option<&Result<Message, axum::Error>>) -> bool {
    matches!(incoming, Some(Ok(message)) if !matches!(message, Message::Close(_)))
}

/// Pass one change on. Returns whether the socket is still usable.
async fn relay(
    socket: &mut WebSocket,
    change: Result<PanelChange, RecvError>,
    viewer: &Viewer,
) -> bool {
    match change {
        Ok(PanelChange::Resynced) => send(socket, &Frame::Resync).await,
        // Not this person's, so there is nothing to send and nothing wrong: the
        // channel carries every change and each socket takes its own share.
        Ok(PanelChange::Pairing(update)) => match pairing_frame(viewer, &update) {
            Some(frame) => send(socket, &frame).await,
            None => true,
        },
        // This browser fell behind and the channel dropped changes it never saw.
        // It is told to re-read rather than closed: it has a working connection
        // and one HTTP request puts it right, where closing would cost it a
        // reconnection to reach the same place.
        Err(RecvError::Lagged(missed)) => {
            record_lag(missed);
            send(socket, &Frame::Resync).await
        }
        Err(RecvError::Closed) => false,
    }
}

/// One change, if this viewer is entitled to it.
///
/// The rule is the pairing list's own, applied to the same shape the list sends,
/// so a person is told about exactly the pairings they would have been shown had
/// they reloaded instead.
fn pairing_frame<'a>(viewer: &Viewer, changed: &'a PairingChanged) -> Option<Frame<'a>> {
    let entry = PanelPairing {
        pairing: changed.pairing.clone(),
        account_id: changed.account_id.clone(),
    };
    visible_to(viewer, &entry).then(|| {
        Frame::Pairing(Box::new(PushedPairing {
            change: changed.change.as_str(),
            pairing: entry,
        }))
    })
}

/// Returns whether the socket is still usable.
async fn send(socket: &mut WebSocket, frame: &Frame<'_>) -> bool {
    let Ok(payload) = serde_json::to_string(frame) else {
        // A frame that cannot be encoded is this panel's bug, not this
        // connection's. Dropping it keeps the socket carrying the ones after.
        record_unencodable();
        return true;
    };
    socket.send(Message::Text(payload.into())).await.is_ok()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_lag(missed: u64) {
    tracing::warn!(missed, "a panel watcher fell behind; asking it to re-read");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_unencodable() {
    tracing::error!("could not encode a panel event");
}

/// What a browser receives.
///
/// Tagged rather than distinguished by which fields are present: the page
/// switches on one value, and a frame the panel grows later reaches an older
/// bundle as something it can recognise and ignore.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Frame<'a> {
    /// Whatever the page is showing may be stale. Re-read the list.
    Resync,
    /// One pairing became something else. The entry is spelled exactly as the
    /// list route spells it, so a page can put it straight into what it already
    /// holds.
    Pairing(Box<PushedPairing<'a>>),
}

/// The body of a [`Frame::Pairing`], boxed so one variant carrying a whole
/// pairing does not set the size of every frame the panel sends.
#[derive(Debug, Serialize)]
struct PushedPairing<'a> {
    change: &'a str,
    pairing: PanelPairing,
}

#[cfg(test)]
mod tests {
    use super::{Frame, PushedPairing};
    use crate::daemon_client::pairings::{DaemonPairing, DaemonPairingDevice};
    use crate::http::pairings::PanelPairing;

    fn claimed() -> PanelPairing {
        PanelPairing {
            account_id: Some("acc_1".to_owned()),
            pairing: DaemonPairing {
                pairing_id: "pair-1".to_owned(),
                state: "active".to_owned(),
                role: "operator".to_owned(),
                created_at: "2026-07-26T10:00:00Z".to_owned(),
                expires_at: "2026-07-26T10:10:00Z".to_owned(),
                claimed_at: Some("2026-07-26T10:01:00Z".to_owned()),
                revoked_at: None,
                device: Some(DaemonPairingDevice {
                    client_id: "device-1".to_owned(),
                    display_name: "Ada's laptop".to_owned(),
                    platform: "macos".to_owned(),
                    last_seen_at: None,
                    revoked_at: None,
                }),
            },
        }
    }

    /// The page holds one type for a pairing and puts what arrives here straight
    /// into the list it already has. Two spellings would be two types, and the
    /// second would be the one nobody remembered to update.
    #[test]
    fn a_pushed_pairing_is_spelled_the_way_the_list_spells_one() {
        let frame = Frame::Pairing(Box::new(PushedPairing {
            change: "claimed",
            pairing: claimed(),
        }));

        let encoded = serde_json::to_value(&frame).expect("serialize the frame");

        assert_eq!(encoded["type"], "pairing");
        assert_eq!(encoded["change"], "claimed");
        assert_eq!(encoded["pairing"]["pairing_id"], "pair-1");
        assert_eq!(encoded["pairing"]["state"], "active");
        assert_eq!(encoded["pairing"]["account_id"], "acc_1");
        assert_eq!(encoded["pairing"]["device"]["display_name"], "Ada's laptop");
    }

    /// The page switches on the tag, so a resync has to carry one rather than
    /// being recognised by what it lacks.
    #[test]
    fn a_resync_names_itself() {
        let encoded = serde_json::to_value(Frame::Resync).expect("serialize the frame");

        assert_eq!(encoded["type"], "resync");
    }
}
