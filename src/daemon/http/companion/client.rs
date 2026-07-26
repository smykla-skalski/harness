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
}
