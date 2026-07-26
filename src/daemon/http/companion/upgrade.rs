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

use std::net::SocketAddr;

use axum::body::Body;
use axum::http::header::{CONNECTION, UPGRADE};
use axum::http::{HeaderMap, HeaderValue, Method, Request, StatusCode};
use axum::response::Response;
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
/// All three conditions, not any: a `GET` carrying `Upgrade: websocket` without
/// the `Connection` token is not a handshake any client will complete, and
/// forwarding it would hand the companion a request it has to refuse on the
/// daemon's behalf.
pub(super) fn requests_websocket_upgrade(method: &Method, headers: &HeaderMap) -> bool {
    method == Method::GET
        && headers
            .get(UPGRADE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.trim().eq_ignore_ascii_case("websocket"))
        && connection_names_upgrade(headers)
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
    // Taken before the request is rebuilt: the upgrade rides in its extensions,
    // and forwarding the request takes them with it.
    let caller = hyper::upgrade::on(&mut request);

    let mut upstream_request = match build_upstream_request(config, peer_addr, request) {
        Ok(request) => request,
        Err(response) => return *response,
    };
    // Restored after the hop-by-hop strip removed them, and normalised rather
    // than copied: whatever else the caller listed in `Connection` was dropped
    // with the rest of that hop, and this is the only directive that belongs on
    // the new one.
    let headers = upstream_request.headers_mut();
    headers.insert(CONNECTION, HeaderValue::from_static("upgrade"));
    headers.insert(UPGRADE, HeaderValue::from_static("websocket"));

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

    let upstream = hyper::upgrade::on(&mut response);
    tokio::spawn(async move {
        let _permit = permit;
        pump(caller, upstream).await;
    });

    // Passed through rather than filtered. The ordinary strip would take
    // `Connection` and `Upgrade`, which on a 101 are the handshake being agreed
    // rather than stale state from the hop before it, and what is left without
    // them — or without the `Sec-WebSocket-Accept` that answers the caller's key
    // — is no handshake at all. The companion is a loopback service the daemon
    // started, not an arbitrary upstream whose headers need policing.
    let (parts, _body) = response.into_parts();
    Response::from_parts(parts, Body::empty())
}

async fn pump(caller: hyper::upgrade::OnUpgrade, upstream: hyper::upgrade::OnUpgrade) {
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
fn report_relay_end(error: &std::io::Error) {
    tracing::debug!(%error, "companion websocket relay ended");
}

fn upstream_unreachable(
    config: &CompanionRouteConfig,
    error: &hyper_util::client::legacy::Error,
) -> Response {
    report_upstream_failure(config.upstream_origin(), error);
    upstream_unreachable_response()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn report_upstream_failure(upstream_origin: &str, error: &hyper_util::client::legacy::Error) {
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
