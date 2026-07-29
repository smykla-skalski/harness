use axum::body::Body;
use axum::http::Version;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;

pub(crate) type SybraClient = Client<HttpConnector, Body>;

pub(crate) struct SybraClients {
    http1: SybraClient,
    http2: SybraClient,
}

impl SybraClients {
    pub(crate) fn new() -> Self {
        let http1 = Client::builder(TokioExecutor::new()).build(HttpConnector::new());
        let mut http2_builder = Client::builder(TokioExecutor::new());
        http2_builder.http2_only(true);
        let http2 = http2_builder.build(HttpConnector::new());
        Self { http1, http2 }
    }

    pub(crate) fn for_version(&self, version: Version) -> &SybraClient {
        if version == Version::HTTP_2 {
            &self.http2
        } else {
            &self.http1
        }
    }
}
