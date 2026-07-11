use std::fmt;
use std::time::Duration;

use async_trait::async_trait;

#[derive(Clone)]
pub struct PublicDnsHttpRequest {
    pub url: String,
    pub authorization: String,
    pub body: String,
}

impl PublicDnsHttpRequest {
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn authorization(&self) -> &str {
        &self.authorization
    }

    pub fn body(&self) -> &str {
        &self.body
    }
}

impl fmt::Debug for PublicDnsHttpRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PublicDnsHttpRequest")
            .field("url", &self.url)
            .field("authorization", &"<redacted>")
            .field("body", &self.body)
            .finish()
    }
}

pub struct PublicDnsHttpResponse {
    pub status: u16,
    pub body: String,
}

#[async_trait]
pub trait PublicDnsHttpClient: Send + Sync {
    async fn send(&self, request: PublicDnsHttpRequest) -> Result<PublicDnsHttpResponse, String>;
}

pub struct ReqwestPublicDnsHttpClient {
    http: reqwest::Client,
}

impl ReqwestPublicDnsHttpClient {
    pub fn new(timeout: Duration) -> Result<Self, String> {
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .map_err(|error| format!("build public DNS HTTP client: {error}"))?;
        Ok(Self { http })
    }
}

#[async_trait]
impl PublicDnsHttpClient for ReqwestPublicDnsHttpClient {
    async fn send(&self, request: PublicDnsHttpRequest) -> Result<PublicDnsHttpResponse, String> {
        let response = self
            .http
            .post(request.url)
            .header("authorization", request.authorization)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(request.body)
            .send()
            .await
            .map_err(|error| format!("send public DNS HTTP request: {}", error.without_url()))?;
        let status = response.status().as_u16();
        let body = response
            .text()
            .await
            .map_err(|error| format!("read public DNS HTTP response: {}", error.without_url()))?;
        Ok(PublicDnsHttpResponse { status, body })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use axum::Router;
    use axum::body::Bytes;
    use axum::extract::State;
    use axum::http::{HeaderMap, StatusCode};
    use axum::routing::post;
    use tokio::net::TcpListener;

    use super::*;

    #[tokio::test]
    async fn reqwest_public_dns_client_posts_form_with_basic_auth() {
        let captured = Arc::new(Mutex::new(None));
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind fake Aftermarket server");
        let address = listener.local_addr().expect("fake server address");
        let app = Router::new()
            .route("/domain/dns/list", post(capture_request))
            .with_state(Arc::clone(&captured));
        let server = tokio::spawn(axum::serve(listener, app).into_future());
        let client = ReqwestPublicDnsHttpClient::new(Duration::from_secs(5))
            .expect("public DNS HTTP client");

        let response = client
            .send(PublicDnsHttpRequest {
                url: format!("http://{address}/domain/dns/list"),
                authorization: "Basic cHVibGljLWtleTpzZWNyZXQta2V5".to_string(),
                body: "name=example.com".to_string(),
            })
            .await
            .expect("send fake Aftermarket request");

        assert_eq!(response.status, 200);
        assert_eq!(response.body, r#"{"ok":1,"data":[]}"#);
        let captured = captured
            .lock()
            .expect("captured request lock")
            .clone()
            .expect("captured request");
        assert_eq!(captured.authorization, "Basic cHVibGljLWtleTpzZWNyZXQta2V5");
        assert_eq!(captured.content_type, "application/x-www-form-urlencoded");
        assert_eq!(captured.body, "name=example.com");
        server.abort();
    }

    #[derive(Clone)]
    struct CapturedRequest {
        authorization: String,
        content_type: String,
        body: String,
    }

    async fn capture_request(
        State(captured): State<Arc<Mutex<Option<CapturedRequest>>>>,
        headers: HeaderMap,
        body: Bytes,
    ) -> (StatusCode, &'static str) {
        let header = |name: &str| {
            headers
                .get(name)
                .and_then(|value| value.to_str().ok())
                .unwrap_or_default()
                .to_string()
        };
        *captured.lock().expect("captured request lock") = Some(CapturedRequest {
            authorization: header("authorization"),
            content_type: header("content-type"),
            body: String::from_utf8(body.to_vec()).expect("UTF-8 request body"),
        });
        (StatusCode::OK, r#"{"ok":1,"data":[]}"#)
    }
}
