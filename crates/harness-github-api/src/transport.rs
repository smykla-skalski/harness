use reqwest::Method;
use reqwest::header::{ACCEPT, AUTHORIZATION, HeaderMap, HeaderValue, IF_NONE_MATCH, USER_AGENT};
use serde_json::Value;

use super::client::GitHubProtectedClient;

const USER_AGENT_VALUE: &str = "harness-github-rate-shield";

impl GitHubProtectedClient {
    pub(super) async fn send_json(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        stale: Option<&super::cache::GitHubCacheHit>,
    ) -> Result<reqwest::Response, reqwest::Error> {
        let mut headers = self.default_headers();
        if method == Method::GET
            && let Some(etag) = stale.and_then(|hit| hit.etag.as_deref())
            && let Ok(value) = HeaderValue::from_str(etag)
        {
            headers.insert(IF_NONE_MATCH, value);
        }
        self.send_request(method, route, body, headers).await
    }

    pub(super) async fn send_json_with_headers(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        extra_headers: HeaderMap,
    ) -> Result<reqwest::Response, reqwest::Error> {
        let mut headers = self.default_headers();
        for (name, value) in extra_headers {
            if let Some(name) = name {
                headers.insert(name, value);
            }
        }
        self.send_request(method, route, body, headers).await
    }

    async fn send_request(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        headers: HeaderMap,
    ) -> Result<reqwest::Response, reqwest::Error> {
        let request = self
            .http
            .request(method, self.route_url(route))
            .headers(headers);
        match body {
            Some(body) => request.json(&body).send().await,
            None => request.send().await,
        }
    }

    fn default_headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(USER_AGENT, HeaderValue::from_static(USER_AGENT_VALUE));
        headers.insert(
            ACCEPT,
            HeaderValue::from_static("application/vnd.github+json"),
        );
        let auth = format!("Bearer {}", self.token);
        if let Ok(value) = HeaderValue::from_str(&auth) {
            headers.insert(AUTHORIZATION, value);
        }
        headers
    }

    fn route_url(&self, route: &str) -> String {
        if route.starts_with("http://") || route.starts_with("https://") {
            return route.to_string();
        }
        format!("{}/{}", self.base_url, route.trim_start_matches('/'))
    }
}
