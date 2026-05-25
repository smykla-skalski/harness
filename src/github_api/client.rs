use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{ACCEPT, AUTHORIZATION, ETAG, HeaderMap, HeaderValue, USER_AGENT};
use reqwest::{Method, StatusCode};
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

use super::budget::{parse_graphql_reset_at, parse_retry_after};
use super::response::{
    GitHubApiResponse, budget_error, cache_state, context_error, ensure_graphql_ok, graphql_data,
    http_status_error, provenance_with_snapshot, request_error, revalidated_response, value_u32,
};
use super::state::{GitHubApiState, InflightGuard, InflightRole, global_state, register_inflight};
use super::{
    GitHubCache, GitHubCachePolicy, GitHubPriority, GitHubRateLimitSnapshot, GitHubRateResource,
    GitHubRequestDescriptor, GitHubResponseProvenance,
};

const DEFAULT_BASE_URL: &str = "https://api.github.com";
const USER_AGENT_VALUE: &str = "harness-github-rate-shield";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub(crate) struct GitHubProtectedClient {
    token: String,
    token_hash: String,
    base_url: String,
    http: reqwest::Client,
    pub(super) state: Arc<GitHubApiState>,
}

impl GitHubProtectedClient {
    pub(crate) fn new(token: &str) -> Result<Self, CliError> {
        Self::with_base_url(token, DEFAULT_BASE_URL)
    }

    pub(crate) fn with_base_url(token: &str, base_url: &str) -> Result<Self, CliError> {
        let token = token.trim();
        if token.is_empty() {
            return Err(CliErrorKind::workflow_io("github token missing").into());
        }
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .build()
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("build github http client: {error}"))
            })?;
        Ok(Self {
            token: token.to_string(),
            token_hash: GitHubCache::key(&["token", token]),
            base_url: base_url.trim_end_matches('/').to_string(),
            http,
            state: global_state(),
        })
    }

    pub(crate) async fn status() -> super::types::GitHubApiStatus {
        let state = global_state();
        state.recorder.status(&state.budget).await
    }

    pub(crate) async fn graphql<T>(
        &self,
        descriptor: GitHubRequestDescriptor,
        body: Value,
    ) -> Result<GitHubApiResponse<T>, CliError>
    where
        T: DeserializeOwned,
    {
        let operation = descriptor.operation.clone();
        let priority = descriptor.priority;
        let raw = self
            .execute_json(Method::POST, "/graphql", Some(body), descriptor)
            .await?;
        let snapshot = self.observe_graphql_rate_limit(&raw).await;
        self.record_network(
            &operation,
            priority,
            &raw,
            GitHubRateResource::Graphql,
            snapshot.as_ref(),
        );
        let data = graphql_data(&raw.body, &raw.provenance)?;
        let body = serde_json::from_value(data).map_err(|error| {
            CliErrorKind::workflow_parse(format!("decode github graphql data: {error}"))
        })?;
        Ok(GitHubApiResponse {
            body,
            provenance: provenance_with_snapshot(raw.provenance, snapshot),
            status_code: raw.status_code,
        })
    }

    pub(crate) async fn graphql_envelope(
        &self,
        descriptor: GitHubRequestDescriptor,
        body: Value,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        let operation = descriptor.operation.clone();
        let priority = descriptor.priority;
        let raw = self
            .execute_json(Method::POST, "/graphql", Some(body), descriptor)
            .await?;
        let snapshot = self.observe_graphql_rate_limit(&raw).await;
        self.record_network(
            &operation,
            priority,
            &raw,
            GitHubRateResource::Graphql,
            snapshot.as_ref(),
        );
        ensure_graphql_ok(&raw.body, &raw.provenance)?;
        Ok(GitHubApiResponse {
            body: raw.body,
            provenance: provenance_with_snapshot(raw.provenance, snapshot),
            status_code: raw.status_code,
        })
    }

    pub(crate) async fn rest_json<T>(
        &self,
        method: Method,
        route: impl AsRef<str>,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
    ) -> Result<GitHubApiResponse<T>, CliError>
    where
        T: DeserializeOwned,
    {
        let resource = descriptor.resource;
        let operation = descriptor.operation.clone();
        let priority = descriptor.priority;
        let raw = self
            .execute_json(method, route.as_ref(), body, descriptor)
            .await?;
        self.record_network(
            &operation,
            priority,
            &raw,
            resource,
            raw.provenance.rate_limit_snapshot.as_ref(),
        );
        let body = serde_json::from_value(raw.body).map_err(|error| {
            CliErrorKind::workflow_parse(format!("decode github rest response: {error}"))
        })?;
        Ok(GitHubApiResponse {
            body,
            provenance: raw.provenance,
            status_code: raw.status_code,
        })
    }

    async fn execute_json(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        let cache_key = self.cache_key(method.as_str(), route, body.as_ref(), &descriptor);
        if !descriptor.cache_policy.force_refresh
            && let Some(hit) = self.state.cache.get(&cache_key, descriptor.cache_policy)
        {
            return Ok(self.cache_response(&descriptor.operation, hit, false));
        }
        let _inflight = self
            .wait_for_singleflight(&cache_key, descriptor.cache_policy)
            .await;
        if !descriptor.cache_policy.force_refresh
            && let Some(hit) = self.state.cache.get(&cache_key, descriptor.cache_policy)
        {
            return Ok(self.cache_response(&descriptor.operation, hit, false));
        }
        let stale = self.state.cache.stale(&cache_key, descriptor.cache_policy);
        let acquire = self
            .state
            .budget
            .acquire(
                descriptor.resource,
                descriptor.priority,
                descriptor.expected_cost,
            )
            .await;
        let _permit = match acquire {
            Ok(permit) => permit,
            Err(error) => {
                if let Some(hit) = stale {
                    return Ok(self.cache_response(&descriptor.operation, hit, true));
                }
                return Err(budget_error(&descriptor.operation, error));
            }
        };
        let response = self
            .send_json(method, route, body, stale.as_ref())
            .await
            .map_err(|error| request_error(&descriptor.operation, error))?;
        self.handle_http_response(response, &cache_key, descriptor.cache_policy, stale)
            .await
            .map_err(|error| context_error(&descriptor.operation, error))
    }

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
            headers.insert(reqwest::header::IF_NONE_MATCH, value);
        }
        let url = self.route_url(route);
        let request = self.http.request(method, url).headers(headers);
        match body {
            Some(body) => request.json(&body).send().await,
            None => request.send().await,
        }
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
        let url = self.route_url(route);
        let request = self.http.request(method, url).headers(headers);
        match body {
            Some(body) => request.json(&body).send().await,
            None => request.send().await,
        }
    }

    async fn handle_http_response(
        &self,
        response: reqwest::Response,
        cache_key: &str,
        policy: GitHubCachePolicy,
        stale: Option<super::cache::GitHubCacheHit>,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        let status = response.status();
        let headers = response.headers().clone();
        let snapshot = self.state.budget.observe_headers(&headers).await;
        if status == StatusCode::NOT_MODIFIED
            && let Some(hit) = stale
        {
            self.state
                .cache
                .store(cache_key, &hit.body, hit.etag.clone(), policy);
            return Ok(revalidated_response(hit.body, snapshot));
        }
        if matches!(status.as_u16(), 403 | 429) {
            self.state
                .budget
                .observe_secondary_limit(
                    snapshot
                        .as_ref()
                        .map_or(GitHubRateResource::Core, |snapshot| snapshot.resource),
                    parse_retry_after(&headers),
                )
                .await;
        }
        let text = response.text().await.map_err(|error| {
            CliErrorKind::workflow_io(format!("read github response body: {error}"))
        })?;
        if !status.is_success() {
            return Err(http_status_error(status, &text));
        }
        let body: Value = serde_json::from_str(&text)
            .map_err(|error| CliErrorKind::workflow_parse(format!("parse github json: {error}")))?;
        let etag = headers
            .get(ETAG)
            .and_then(|value| value.to_str().ok())
            .map(ToString::to_string);
        self.state.cache.store(cache_key, &body, etag, policy);
        Ok(GitHubApiResponse {
            body,
            provenance: GitHubResponseProvenance::network(snapshot),
            status_code: Some(status.as_u16()),
        })
    }

    fn cache_response(
        &self,
        operation: &str,
        hit: super::cache::GitHubCacheHit,
        deferred: bool,
    ) -> GitHubApiResponse<Value> {
        if deferred {
            self.state
                .recorder
                .record_deferred_budget(operation, hit.state);
        } else {
            self.state.recorder.record_cache_hit(operation, hit.state);
        }
        GitHubApiResponse {
            body: hit.body,
            provenance: GitHubResponseProvenance {
                from_cache: true,
                cache_age_seconds: Some(hit.age_seconds),
                cache_state: cache_state(hit.state, deferred),
                rate_limit_snapshot: None,
            },
            status_code: None,
        }
    }

    async fn wait_for_singleflight(
        &self,
        cache_key: &str,
        policy: GitHubCachePolicy,
    ) -> Option<InflightGuard> {
        if !policy.is_enabled() {
            return None;
        }
        loop {
            match register_inflight(&self.state, cache_key) {
                InflightRole::Leader(guard) => return Some(guard),
                InflightRole::Follower(notify) => notify.notified().await,
            }
        }
    }

    async fn observe_graphql_rate_limit(
        &self,
        response: &GitHubApiResponse<Value>,
    ) -> Option<GitHubRateLimitSnapshot> {
        let rate = response.body.pointer("/data/rateLimit")?;
        let remaining = value_u32(rate.get("remaining"))?;
        let limit = value_u32(rate.get("limit")).unwrap_or(remaining);
        let cost = value_u32(rate.get("cost")).unwrap_or(0);
        let reset_at = rate
            .get("resetAt")
            .and_then(Value::as_str)
            .and_then(parse_graphql_reset_at)?;
        Some(
            self.state
                .budget
                .observe_graphql_rate_limit(remaining, limit, cost, reset_at)
                .await,
        )
    }

    fn record_network(
        &self,
        operation: &str,
        priority: GitHubPriority,
        response: &GitHubApiResponse<Value>,
        resource: GitHubRateResource,
        snapshot: Option<&GitHubRateLimitSnapshot>,
    ) {
        if let Some(status) = response.status_code {
            self.state.recorder.record_network(
                operation,
                resource,
                priority,
                Some(status),
                snapshot.and_then(|snapshot| snapshot.cost).unwrap_or(0),
            );
        }
    }

    fn cache_key(
        &self,
        method: &str,
        route: &str,
        body: Option<&Value>,
        descriptor: &GitHubRequestDescriptor,
    ) -> String {
        let body = body.map_or_else(String::new, Value::to_string);
        GitHubCache::key(&[
            &self.token_hash,
            &self.base_url,
            method,
            route,
            descriptor.operation.as_str(),
            body.as_str(),
        ])
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
