use axum::body::Body;
use axum::http::Version;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;

pub(super) type CompanionClient = Client<HttpConnector, Body>;

pub(super) struct CompanionClients {
    http1: CompanionClient,
    http2: CompanionClient,
}

impl CompanionClients {
    pub(super) fn new() -> Self {
        // Plain HttpConnector cannot advertise HTTP/2 through ALPN, so the
        // automatic client remains HTTP/1 on this cleartext loopback hop.
        let http1 = Client::builder(TokioExecutor::new()).build(HttpConnector::new());
        let mut http2_builder = Client::builder(TokioExecutor::new());
        http2_builder.http2_only(true);
        let http2 = http2_builder.build(HttpConnector::new());
        Self { http1, http2 }
    }

    pub(super) fn for_version(&self, version: Version) -> &CompanionClient {
        if version == Version::HTTP_2 {
            &self.http2
        } else {
            &self.http1
        }
    }

    /// The panel speaks HTTP/1.1 websockets, and the h2 client strips the
    /// `Connection`/`Upgrade` handshake headers, so a relay always takes this
    /// client regardless of the caller's version.
    pub(super) fn http1(&self) -> &CompanionClient {
        &self.http1
    }
}
