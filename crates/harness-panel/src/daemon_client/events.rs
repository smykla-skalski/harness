//! The socket the panel holds open to the daemon.
//!
//! The daemon announces a mint, a claim, or a revoke the moment it commits one,
//! and this is the panel's end of that. It runs for as long as the panel does,
//! reconnecting on its own, because a connection that stayed down would leave
//! every open browser quietly showing a link that had already been claimed.
//!
//! It carries the panel's ordinary broker credential and asks for nothing more
//! than the pairing routes already grant. The daemon narrows the stream to what
//! that credential minted, so what arrives here is the panel's own and nothing
//! else — the same answer the list route gives, pushed instead of asked for.
//!
//! Nothing is replayed on connect, so a socket that has just come up says only
//! that the picture may be stale. That is announced as a resync, and whoever is
//! watching re-reads.

use std::time::{Duration, Instant};

use futures_util::{SinkExt as _, StreamExt as _};
use rustls::pki_types::ServerName;
use serde::Deserialize;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::time::{interval, sleep};
use tokio_rustls::TlsConnector;
use tokio_rustls::client::TlsStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::header::{AUTHORIZATION, USER_AGENT};
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::{Bytes, Message};
use tokio_tungstenite::{WebSocketStream, client_async};
use url::Url;

use super::pairings::DaemonPairing;
use super::{CLIENT_ID_HEADER, DaemonClient, DaemonCredential};
use crate::error::PanelError;
use crate::events::{PairingChanged, PanelChange, PanelEvents};
use crate::store::Store;

/// The daemon route this opens. One channel for remote clients generally rather
/// than one per subject, so a stream the daemon grows later needs no second
/// connection from here.
const EVENT_ROUTE: &str = "/v1/remote/ws";

/// How long to wait before the first reconnection attempt, and the ceiling the
/// wait doubles towards. The floor is short because the common cause is the
/// daemon restarting under an upgrade, which is over in a second or two.
const FIRST_RETRY: Duration = Duration::from_secs(1);
const MAX_RETRY: Duration = Duration::from_secs(30);

/// How long a panel with no daemon credential waits between looks.
///
/// Pairing the panel is a one-off an operator performs by hand, so this is a
/// long quiet poll for a file that will not appear on its own, kept only so
/// that pairing an already-running panel does not also require restarting it.
const UNPAIRED_RETRY: Duration = Duration::from_mins(1);

/// How long a connection has to survive before it counts as good and the
/// backoff goes back to its floor. Without this, a daemon that accepts the
/// socket and immediately closes it would be reconnected to as fast as the
/// panel could dial.
const STABLE_AFTER: Duration = Duration::from_secs(30);

/// How often the panel pings, and how long it will sit in silence first.
///
/// A dropped connection is not always reported: a middlebox that forgets the
/// flow leaves both ends believing they are still attached, and a panel in that
/// state would go on serving a page nothing ever updates. The limit is three
/// intervals, so one lost pong is not a disconnection.
const PING_INTERVAL: Duration = Duration::from_secs(30);
const SILENCE_LIMIT: Duration = Duration::from_secs(95);

/// What one connection attempt came to.
#[derive(Debug)]
enum Attempt {
    /// The panel has not been paired with a daemon yet, so there is nothing to
    /// authenticate with. Not a failure: it is the state a freshly installed
    /// panel is in until an operator runs `harness-panel pair`.
    Unpaired,
    /// The socket was open and is not any more.
    Closed { opened: Instant },
}

/// Holds the daemon socket open and announces what comes down it.
#[derive(Debug)]
pub struct DaemonEventStream {
    client: DaemonClient,
    store: Store,
    events: PanelEvents,
}

impl DaemonEventStream {
    #[must_use]
    pub fn new(client: DaemonClient, store: Store, events: PanelEvents) -> Self {
        Self {
            client,
            store,
            events,
        }
    }

    /// Reconnect for as long as the panel runs. Never returns.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub async fn run(self) {
        let mut backoff = FIRST_RETRY;
        loop {
            match self.attempt().await {
                Ok(Attempt::Unpaired) => {
                    // The backoff counts consecutive failures to reach the
                    // daemon, and nothing was reached for or failed here. Left
                    // standing, it would make the first attempt after somebody
                    // pairs the panel wait out a delay earned before they did.
                    backoff = FIRST_RETRY;
                    sleep(UNPAIRED_RETRY).await;
                    continue;
                }
                Ok(Attempt::Closed { opened }) => {
                    tracing::info!("the daemon event socket closed");
                    if opened.elapsed() >= STABLE_AFTER {
                        backoff = FIRST_RETRY;
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "the daemon event socket is down");
                }
            }
            sleep(backoff).await;
            backoff = (backoff * 2).min(MAX_RETRY);
        }
    }

    /// One connection, from dialling to whatever ended it.
    async fn attempt(&self) -> Result<Attempt, PanelError> {
        let Some(credential) = self.store.daemon_credential().await? else {
            return Ok(Attempt::Unpaired);
        };
        let socket = self.client.open_event_socket(&credential).await?;
        let opened = Instant::now();
        // Announced only once the socket is up. The other order would have a
        // watcher re-read while the panel was still unattached, and every change
        // between that read and the socket opening would be lost with nothing
        // left to say so.
        self.events.announce(PanelChange::Resynced);

        match socket {
            EventSocket::Plain(socket) => self.pump(*socket).await?,
            EventSocket::Secured(socket) => self.pump(*socket).await?,
        }
        Ok(Attempt::Closed { opened })
    }

    /// Read until the socket ends or stops answering.
    async fn pump<S>(&self, mut socket: WebSocketStream<S>) -> Result<(), PanelError>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let mut heartbeat = interval(PING_INTERVAL);
        // The first tick fires immediately and would ping a socket opened this
        // instant, which proves nothing and only costs a frame.
        heartbeat.tick().await;
        let mut heard = Instant::now();

        loop {
            tokio::select! {
                incoming = socket.next() => {
                    let Some(message) = incoming else { return Ok(()) };
                    let message = message.map_err(|error| {
                        PanelError::daemon(format!("reading a daemon event: {error}"))
                    })?;
                    // Any frame at all, including the pong to a ping below: this
                    // is about the connection carrying traffic, not about what
                    // the traffic said.
                    heard = Instant::now();
                    match message {
                        Message::Text(payload) => self.announce(payload.as_str()).await,
                        Message::Close(_) => return Ok(()),
                        _ => {}
                    }
                }
                _ = heartbeat.tick() => {
                    if heard.elapsed() >= SILENCE_LIMIT {
                        return Err(PanelError::daemon(
                            "the daemon stopped answering the event socket",
                        ));
                    }
                    socket.send(Message::Ping(Bytes::new())).await.map_err(|error| {
                        PanelError::daemon(format!("pinging the daemon event socket: {error}"))
                    })?;
                }
            }
        }
    }

    /// Turn one daemon frame into something a watcher can act on.
    ///
    /// A frame that cannot be read is the daemon's business rather than this
    /// connection's, so it is recorded and skipped: dropping the socket over one
    /// would cost every change that follows.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    async fn announce(&self, payload: &str) {
        let event: DaemonPairingEvent = match serde_json::from_str(payload) {
            Ok(event) => event,
            Err(error) => {
                tracing::warn!(%error, "could not read a daemon event");
                return;
            }
        };

        match self
            .store
            .pair_link_account(&event.pairing.pairing_id)
            .await
        {
            Ok(account_id) => self.events.announce(PanelChange::Pairing(
                PairingChanged {
                    change: event.change,
                    pairing: event.pairing,
                    account_id,
                }
                .into(),
            )),
            // Without the account there is no telling whose row this is, and
            // guessing would put one person's device on another's page. A
            // resync sends every watcher back to the list route, which resolves
            // attribution itself and answers honestly if it cannot.
            Err(error) => {
                tracing::warn!(%error, "could not attribute a daemon event; asking watchers to re-read");
                self.events.announce(PanelChange::Resynced);
            }
        }
    }
}

/// The daemon socket, however it had to be reached.
///
/// Two shapes rather than one behind a trait object: the loop that reads them
/// is generic and monomorphises twice, which costs a match arm here and saves a
/// dynamic dispatch on every frame.
enum EventSocket {
    Plain(Box<WebSocketStream<TcpStream>>),
    Secured(Box<WebSocketStream<TlsStream<TcpStream>>>),
}

impl DaemonClient {
    /// Dial the daemon's event route with the panel's own credential.
    async fn open_event_socket(
        &self,
        credential: &DaemonCredential,
    ) -> Result<EventSocket, PanelError> {
        let url = self.event_socket_url()?;
        let secured = url.scheme() == "wss";
        let mut request = url.as_str().into_client_request().map_err(|error| {
            PanelError::daemon(format!("building the daemon event request: {error}"))
        })?;
        let headers = request.headers_mut();
        headers.insert(
            HeaderName::from_static(CLIENT_ID_HEADER),
            header_value(&credential.client_id)?,
        );
        headers.insert(
            AUTHORIZATION,
            header_value(&format!("Bearer {}", credential.token))?,
        );
        headers.insert(
            USER_AGENT,
            header_value(concat!("harness-panel/", env!("CARGO_PKG_VERSION")))?,
        );

        let tcp = self.dial(&url).await?;
        if !secured {
            let (socket, _) = client_async(request, tcp).await.map_err(|error| {
                PanelError::daemon(format!("opening the daemon event socket: {error}"))
            })?;
            return Ok(EventSocket::Plain(Box::new(socket)));
        }

        let name = ServerName::try_from(self.domain.clone()).map_err(|error| {
            PanelError::daemon(format!("the daemon domain is unusable: {error}"))
        })?;
        let tls = TlsConnector::from(self.tls.clone())
            .connect(name, tcp)
            .await
            .map_err(|error| {
                PanelError::daemon(format!("the daemon event handshake failed: {error}"))
            })?;
        let (socket, _) = client_async(request, tls).await.map_err(|error| {
            PanelError::daemon(format!("opening the daemon event socket: {error}"))
        })?;
        Ok(EventSocket::Secured(Box::new(socket)))
    }

    async fn dial(&self, url: &Url) -> Result<TcpStream, PanelError> {
        TcpStream::connect(dial_authority(url)?)
            .await
            .map_err(|error| PanelError::daemon(format!("reaching the daemon: {error}")))
    }

    /// The event route, as a websocket URL.
    ///
    /// Derived from the configured endpoint rather than spelled out, so a daemon
    /// behind a reverse proxy at a prefix is reached the same way its HTTP
    /// routes already are.
    fn event_socket_url(&self) -> Result<Url, PanelError> {
        let mut url = self.route(EVENT_ROUTE);
        let scheme = match url.scheme() {
            "https" => "wss",
            // Only loopback ever gets here: the configuration refuses plain HTTP
            // anywhere else, because the pin is what authenticates the far end
            // and there is no handshake to check it in.
            "http" => "ws",
            other => {
                return Err(PanelError::daemon(format!(
                    "the daemon endpoint scheme {other:?} has no websocket form"
                )));
            }
        };
        url.set_scheme(scheme)
            .map_err(|()| PanelError::daemon("the daemon endpoint cannot address a websocket"))?;
        Ok(url)
    }
}

/// The `host:port` to open the connection on.
///
/// A literal IPv6 address has to be dialled bracketed, and `host_str` already
/// spells it that way — it slices the host out of the serialized URL, brackets
/// included. Written as its own function so the test below can hold that, since
/// an unbracketed host would give `::1:8443` and leave the panel unable to reach
/// a daemon on an IPv6 address at all.
fn dial_authority(url: &Url) -> Result<String, PanelError> {
    let host = url
        .host_str()
        .ok_or_else(|| PanelError::daemon("the daemon endpoint has no host"))?;
    let port = url
        .port_or_known_default()
        .ok_or_else(|| PanelError::daemon("the daemon endpoint has no port"))?;
    Ok(format!("{host}:{port}"))
}

/// Refuse a credential that cannot go in a header rather than sending part of
/// it. A token carrying a newline would otherwise be truncated into a request
/// that authenticates as nobody, and the failure would land on the daemon's
/// side of a socket nobody is watching.
fn header_value(value: &str) -> Result<HeaderValue, PanelError> {
    value
        .parse()
        .map_err(|_| PanelError::daemon("the daemon credential cannot be sent as a header"))
}

/// One change, as the daemon spells it on the wire.
#[derive(Debug, Deserialize)]
struct DaemonPairingEvent {
    change: String,
    pairing: DaemonPairing,
}

#[cfg(test)]
mod tests;
