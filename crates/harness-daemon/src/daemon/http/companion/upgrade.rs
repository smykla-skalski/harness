//! Relaying a websocket handshake to the companion, and then getting out of the
//! way.
//!
//! The daemon is the only thing on the public origin, so a companion that wants
//! to push anything to a browser has to be reached through here. Everything else
//! this module's neighbours do is request-and-answer; this one hands over the
//! connection and copies bytes until one side stops.
//!
//! Only `websocket` is relayed. Every other upgrade — and `CONNECT` — still gets
//! the honest refusal, because relaying a protocol the daemon cannot reason
//! about would turn a scoped companion prefix into a general tunnel off the
//! public listener.

use std::io::Error as IoError;
use std::net::SocketAddr;

use axum::body::Body;
use axum::http::header::{CONNECTION, SEC_WEBSOCKET_KEY, SEC_WEBSOCKET_VERSION, UPGRADE};
use axum::http::{Extensions, HeaderMap, HeaderValue, Method, Request, StatusCode, Version};
use axum::response::Response;
use hyper::upgrade::{OnUpgrade, on};
use hyper_util::client::legacy::Error as ClientError;
use hyper_util::rt::TokioIo;
use tokio::io::copy_bidirectional;
use tokio::sync::OwnedSemaphorePermit;
use tokio::time::{Instant, timeout_at};

use super::CompanionRouteConfig;
use super::client::CompanionClient;
use super::forward::{
    COMPANION_UPSTREAM_TIMEOUT, build_upstream_request, connection_names_upgrade,
    upstream_response, upstream_timeout_response, upstream_unreachable_response,
};

/// Whether this request is the one upgrade the daemon relays.
///
/// Protocol selection and nothing else: websocket is carried, `CONNECT` and
/// every other upgrade is not. Whether a websocket handshake is well formed is
/// the companion's to judge — it answers a missing `Sec-WebSocket-Key` by naming
/// it, and that refusal reaches the caller intact — so checking it here would
/// only let the daemon refuse on behalf of an endpoint that was never asked, in
/// words less precise than the ones it would have used.
///
/// Both header spellings are required because a request carrying one without the
/// other is not asking for the upgrade this relays: `Upgrade` alone names a
/// protocol nobody agreed to switch to, and the `Connection` token alone names
/// no protocol at all.
pub(super) fn requests_websocket_upgrade(method: &Method, headers: &HeaderMap) -> bool {
    method == Method::GET
        && headers
            .get(UPGRADE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.trim().eq_ignore_ascii_case("websocket"))
        && connection_names_upgrade(headers)
}

/// Whether this request asks to relay a websocket, in either spelling.
///
/// A browser reaching the daemon over HTTP/2 opens the socket as an RFC 8441
/// extended `CONNECT` - method `CONNECT` carrying a `:protocol` of `websocket`,
/// which hyper surfaces as a [`hyper::ext::Protocol`] extension - not the
/// HTTP/1.1 `Upgrade` handshake. Both are the same request the relay carries;
/// they differ only in how the wire framed it.
pub(super) fn is_websocket_upgrade(request: &Request<Body>) -> bool {
    requests_websocket_upgrade(request.method(), request.headers())
        || requests_h2_websocket_connect(request.method(), request.extensions())
}

fn requests_h2_websocket_connect(method: &Method, extensions: &Extensions) -> bool {
    method == Method::CONNECT
        && extensions
            .get::<hyper::ext::Protocol>()
            .is_some_and(|protocol| protocol.as_str().eq_ignore_ascii_case("websocket"))
}

/// Hand one websocket connection over to the companion.
///
/// `permit` bounds how many of these may be open at once and is held for the
/// life of the relay, not the life of the handshake — the ceiling is about
/// connections the daemon is carrying, and a socket that has been established is
/// exactly that.
pub(super) async fn relay_websocket(
    config: &CompanionRouteConfig,
    client: &CompanionClient,
    peer_addr: SocketAddr,
    mut request: Request<Body>,
    permit: Option<OwnedSemaphorePermit>,
) -> Response {
    // An h2 caller opened this as an extended `CONNECT`; the handshake it
    // expects back is a `200`, not the `101` an h1 caller and the panel exchange.
    let caller_is_h2 = requests_h2_websocket_connect(request.method(), request.extensions());
    // Taken before the request is rebuilt: the upgrade rides in its extensions,
    // and forwarding the request takes them with it.
    let caller = on(&mut request);

    let mut upstream_request = match build_upstream_request(config, peer_addr, request) {
        Ok(request) => request,
        Err(response) => return *response,
    };
    set_upstream_handshake(&mut upstream_request, caller_is_h2);

    let deadline = Instant::now() + COMPANION_UPSTREAM_TIMEOUT;
    let mut response = match timeout_at(deadline, client.request(upstream_request)).await {
        Ok(Ok(response)) => response,
        Ok(Err(error)) => return upstream_unreachable(config, &error),
        Err(_) => return upstream_timeout_response(),
    };

    if response.status() != StatusCode::SWITCHING_PROTOCOLS {
        // The companion looked at the handshake and said no — an unauthenticated
        // browser, or a path it does not serve a socket on. That is an ordinary
        // answer and goes back the ordinary way, headers and body intact: a
        // `WWW-Authenticate` or an error envelope is the companion telling the
        // caller what to do about it, and this path has no better guess.
        return upstream_response(response, deadline, config.upstream_origin());
    }

    let upstream = on(&mut response);
    tokio::spawn(async move {
        let _permit = permit;
        pump(caller, upstream).await;
    });

    if caller_is_h2 {
        // The h1-only handshake headers the panel answered with mean nothing to
        // an h2 caller and are illegal on an h2 response; a bare `200` is what
        // completes its extended `CONNECT` and yields the upgraded stream.
        return Response::new(Body::empty());
    }

    // Passed through rather than filtered. The ordinary strip would take
    // `Connection` and `Upgrade`, which on a 101 are the handshake being agreed
    // rather than stale state from the hop before it, and what is left without
    // them — or without the `Sec-WebSocket-Accept` that answers the caller's key
    // — is no handshake at all. The companion is a loopback service the daemon
    // started, not an arbitrary upstream whose headers need policing.
    let (parts, _body) = response.into_parts();
    Response::from_parts(parts, Body::empty())
}

/// Any valid 16-byte base64 nonce. An h2 extended `CONNECT` carries no
/// `Sec-WebSocket-Key`, so one is synthesised for the h1 hop; the daemon never
/// checks the `Sec-WebSocket-Accept` the panel derives from it, so the value
/// only has to be well formed, not unique.
const H2_BRIDGE_WEBSOCKET_KEY: &str = "dGhlIHNhbXBsZSBub25jZQ==";

/// Shape the upstream request into the h1 handshake the panel answers.
///
/// An h1 caller already arrived as a `GET` carrying its own `Sec-WebSocket-*`,
/// so only the hop-by-hop directives stripped in [`build_upstream_request`] are
/// restored. An h2 caller arrived as a bodyless extended `CONNECT` with none of
/// that, so its method and the missing handshake headers are synthesised — the
/// panel serves the socket as a `GET` upgrade and cannot answer a `CONNECT`.
fn set_upstream_handshake(request: &mut Request<Body>, caller_is_h2: bool) {
    // The panel speaks HTTP/1.1 websockets, and an h2 caller's request still
    // carries its own version and method here.
    *request.version_mut() = Version::HTTP_11;
    if caller_is_h2 {
        *request.method_mut() = Method::GET;
    }
    let headers = request.headers_mut();
    // Normalised rather than copied: whatever else the caller listed in
    // `Connection` was dropped with the rest of that hop, and this is the only
    // directive that belongs on the new one.
    headers.insert(CONNECTION, HeaderValue::from_static("upgrade"));
    headers.insert(UPGRADE, HeaderValue::from_static("websocket"));
    if caller_is_h2 {
        headers.insert(SEC_WEBSOCKET_VERSION, HeaderValue::from_static("13"));
        headers.insert(
            SEC_WEBSOCKET_KEY,
            HeaderValue::from_static(H2_BRIDGE_WEBSOCKET_KEY),
        );
    }
}

async fn pump(caller: OnUpgrade, upstream: OnUpgrade) {
    let (caller, upstream) = match tokio::try_join!(caller, upstream) {
        Ok(halves) => halves,
        Err(error) => {
            report_incomplete_upgrade(&error);
            return;
        }
    };
    let mut caller = TokioIo::new(caller);
    let mut upstream = TokioIo::new(upstream);
    // Whatever ends it — either side closing, or the connection dropping — is
    // ordinary for a socket held open for minutes. Nothing here can act on it,
    // and both halves are dropped either way.
    if let Err(error) = copy_bidirectional(&mut caller, &mut upstream).await {
        report_relay_end(&error);
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report_incomplete_upgrade(error: &hyper::Error) {
    tracing::warn!(%error, "companion websocket upgrade did not complete");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report_relay_end(error: &IoError) {
    tracing::debug!(%error, "companion websocket relay ended");
}

fn upstream_unreachable(config: &CompanionRouteConfig, error: &ClientError) -> Response {
    report_upstream_failure(config.upstream_origin(), error);
    upstream_unreachable_response()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report_upstream_failure(upstream_origin: &str, error: &ClientError) {
    tracing::warn!(
        upstream = upstream_origin,
        %error,
        "companion websocket handshake failed"
    );
}

#[cfg(test)]
mod tests {
    use axum::http::header::{CONNECTION, UPGRADE};
    use axum::http::{HeaderMap, HeaderValue, Method};

    use super::requests_websocket_upgrade;

    fn handshake_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(UPGRADE, HeaderValue::from_static("websocket"));
        headers.insert(CONNECTION, HeaderValue::from_static("keep-alive, Upgrade"));
        headers
    }

    /// What a browser actually sends, including the mixed case and the extra
    /// token browsers put in `Connection`.
    #[test]
    fn a_browser_handshake_is_recognised() {
        assert!(requests_websocket_upgrade(
            &Method::GET,
            &handshake_headers()
        ));

        let mut cased = HeaderMap::new();
        cased.insert(UPGRADE, HeaderValue::from_static("WebSocket"));
        cased.insert(CONNECTION, HeaderValue::from_static("Upgrade"));
        assert!(requests_websocket_upgrade(&Method::GET, &cased));
    }

    /// Anything else that asks for an upgrade keeps the refusal. Relaying a
    /// protocol the daemon cannot reason about would make a companion prefix a
    /// general tunnel off the public listener.
    #[test]
    fn no_other_upgrade_is_relayed() {
        let mut other = HeaderMap::new();
        other.insert(UPGRADE, HeaderValue::from_static("h2c"));
        other.insert(CONNECTION, HeaderValue::from_static("Upgrade"));
        assert!(!requests_websocket_upgrade(&Method::GET, &other));

        assert!(!requests_websocket_upgrade(
            &Method::CONNECT,
            &handshake_headers()
        ));
    }

    /// A `GET` carrying only half the handshake is not one, and forwarding it
    /// would make the companion refuse on the daemon's behalf.
    #[test]
    fn half_a_handshake_is_not_one() {
        let mut without_connection = HeaderMap::new();
        without_connection.insert(UPGRADE, HeaderValue::from_static("websocket"));
        assert!(!requests_websocket_upgrade(
            &Method::GET,
            &without_connection
        ));

        let mut without_upgrade = HeaderMap::new();
        without_upgrade.insert(CONNECTION, HeaderValue::from_static("Upgrade"));
        assert!(!requests_websocket_upgrade(&Method::GET, &without_upgrade));

        assert!(!requests_websocket_upgrade(&Method::GET, &HeaderMap::new()));
    }

    /// The method matters: a `POST` shaped like a handshake is not one, and the
    /// body it may carry has nowhere to go once the connection is handed over.
    #[test]
    fn only_a_get_is_a_handshake() {
        for method in [Method::POST, Method::PUT, Method::DELETE, Method::HEAD] {
            assert!(
                !requests_websocket_upgrade(&method, &handshake_headers()),
                "{method}"
            );
        }
    }
}
