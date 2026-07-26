//! The websocket a remote client holds open to be told what changed.
//!
//! One upgrade for remote clients generally rather than one per subject, so a
//! later stream needs no second path. Today it carries pairing events alone,
//! which is why the route is gated on `pair_manage`: the gate is the weakest
//! scope any of its traffic requires, and a stream needing another scope has to
//! widen it.
//!
//! Nothing is replayed on connect. The socket reports changes from the moment
//! it is open, and a client that needs the current state reads the inventory
//! over HTTP, which is the request that answers that question.

use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{State, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::response::Response;
use tokio::sync::broadcast::Receiver;
use tokio::sync::broadcast::error::RecvError;

use crate::daemon::db::RemotePairingOwner;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_identity::RemoteStoredClient;
use crate::daemon::remote_pairing::{RemotePairingChange, RemotePairingEvent};

use super::{DaemonHttpState, authenticated_remote_client, prepare_remote_websocket_upgrade};

pub(crate) async fn remote_ws_upgrade(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    ws: WebSocketUpgrade,
) -> Response {
    let client = match authenticated_remote_client(&headers, &state) {
        Ok(client) => client,
        Err(response) => return *response,
    };
    // Resolved before the upgrade, so what this socket may carry is fixed by
    // the credential that opened it. Deciding per event against a client record
    // read later would let a scope change mid-connection widen a socket that
    // was already open.
    let audience = pairing_audience(client.as_ref());
    let (ws, permit) = match prepare_remote_websocket_upgrade(ws, &state) {
        Ok(prepared) => prepared,
        Err(response) => return *response,
    };
    let events = state.remote_pairing_events.subscribe();
    ws.on_upgrade(move |socket| async move {
        let _permit = permit;
        serve_remote_events(socket, events, audience).await;
    })
}

/// Tell whoever is listening that a pairing changed.
///
/// Best effort in both directions. A daemon with no companion attached has no
/// subscribers, which is the ordinary case and not a failure, and a read that
/// cannot be made is recorded rather than raised: the change itself has already
/// happened and committed, so failing the request that caused it would report a
/// completed action as having failed.
pub(crate) fn publish_pairing_change(
    state: &DaemonHttpState,
    change: RemotePairingChange,
    pairing_id: &str,
) {
    // Nobody is listening, so there is nothing to read the row for. Checked
    // before the query rather than after, because this runs on the path of
    // every claim, mint and revoke on a daemon that usually has no companion.
    if state.remote_pairing_events.receiver_count() == 0 {
        return;
    }
    let Some(db) = state.db.get() else { return };
    let Ok(db) = db.lock() else { return };
    let now = crate::workspace::utc_now();
    let read = db
        .remote_pairing_inventory_entry(pairing_id, now.as_str())
        .and_then(|entry| Ok((entry, db.remote_pairing_minted_by(pairing_id)?)));
    drop(db);

    match read {
        Ok((Some(pairing), owner)) => {
            let event = RemotePairingEvent {
                change,
                pairing,
                minted_by: match owner {
                    RemotePairingOwner::Client(client_id) => Some(client_id),
                    RemotePairingOwner::Host | RemotePairingOwner::Unknown => None,
                },
            };
            // Fails only when the last receiver went away between the count
            // above and here, which is the same as nobody listening.
            let _ = state.remote_pairing_events.send(Arc::new(event));
        }
        // The row is gone already. A pairing can be deleted between the change
        // and this read, and an event about a row nobody can look up is worse
        // than none.
        Ok((None, _)) => {}
        Err(error) => {
            tracing::warn!(%error, %pairing_id, "could not read a pairing to announce its change");
        }
    }
}

/// Announce the claim a device just made.
///
/// Resolves the pairing from the client the claim minted, because a claim is
/// spent by code and never names the row it consumed.
pub(crate) fn publish_pairing_claim(state: &DaemonHttpState, client_id: &str) {
    if state.remote_pairing_events.receiver_count() == 0 {
        return;
    }
    let Some(db) = state.db.get() else { return };
    let Ok(db) = db.lock() else { return };
    let claimed = db.remote_pairing_claimed_by(client_id);
    drop(db);

    match claimed {
        Ok(Some(pairing_id)) => {
            publish_pairing_change(state, RemotePairingChange::Claimed, pairing_id.as_str());
        }
        Ok(None) => {}
        Err(error) => {
            tracing::warn!(%error, %client_id, "could not resolve the pairing a device claimed");
        }
    }
}

/// Which pairings this credential may be told about.
///
/// `None` means every one of them. The rule is the listing query's, so a client
/// sees the same pairings pushed to it that it would have read over HTTP; a
/// socket that showed more would be a way around the narrowing that route does.
fn pairing_audience(client: Option<&RemoteStoredClient>) -> Option<String> {
    match client {
        // Local mode has no client and is already the host operator.
        None => None,
        Some(client) if client.scopes.contains(&RemoteAccessScope::Admin) => None,
        Some(client) => Some(client.client_id.clone()),
    }
}

async fn serve_remote_events(
    mut socket: WebSocket,
    mut events: Receiver<Arc<RemotePairingEvent>>,
    audience: Option<String>,
) {
    loop {
        tokio::select! {
            // Drains what the peer sends so a close frame ends the connection
            // promptly. The daemon answers nothing here: this socket is one
            // way, and a client with something to ask has the HTTP routes.
            incoming = socket.recv() => match incoming {
                None | Some(Err(_) | Ok(Message::Close(_))) => return,
                Some(Ok(_)) => {}
            },
            event = events.recv() => match event {
                Ok(event) => {
                    if !event.visible_to(audience.as_deref()) {
                        continue;
                    }
                    let Ok(payload) = serde_json::to_string(event.as_ref()) else {
                        // An event that cannot be encoded is this daemon's bug,
                        // not this connection's. Dropping the frame keeps the
                        // socket carrying the ones that follow.
                        tracing::error!(
                            pairing_id = %event.pairing.pairing_id,
                            "could not encode a remote pairing event"
                        );
                        continue;
                    };
                    if socket.send(Message::Text(payload.into())).await.is_err() {
                        return;
                    }
                }
                // The subscriber fell behind and the channel dropped events it
                // never saw. Closing says so plainly: the client reconnects and
                // re-reads the inventory, which is correct, where carrying on
                // would leave it quietly missing a change it will never be told
                // about.
                Err(RecvError::Lagged(missed)) => {
                    tracing::warn!(missed, "remote event subscriber lagged; closing the socket");
                    return;
                }
                Err(RecvError::Closed) => return,
            },
        }
    }
}
