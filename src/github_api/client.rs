use std::sync::Arc;

use reqwest::header::{ETAG, HeaderMap};
use reqwest::{Method, StatusCode};
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::sync::broadcast;

use crate::errors::{CliError, CliErrorKind};

use super::budget::{parse_graphql_reset_at, parse_retry_after};
use super::response::{
    GitHubApiResponse, budget_error, cache_state, context_error, ensure_graphql_ok, graphql_data,
    http_status_error, provenance_with_snapshot, request_error, revalidated_response, value_u32,
};
use super::state::{
    GitHubApiState, GitHubMutationGuard, InflightGuard, InflightRole, global_state,
    register_inflight,
};
use super::{
    GitHubCache, GitHubCachePolicy, GitHubPriority, GitHubRateLimitSnapshot, GitHubRateResource,
    GitHubRequestDescriptor, GitHubResponseProvenance, retry_stable_read,
};

const DEFAULT_BASE_URL: &str = "https://api.github.com";
#[derive(Clone)]
pub(crate) struct GitHubProtectedClient {
    pub(super) token: String,
    token_hash: String,
    pub(super) base_url: String,
    pub(super) http: reqwest::Client,
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
        let state = global_state();
        let http = state.http.clone().map_err(|error| {
            CliErrorKind::workflow_io(format!("build github http client: {error}"))
        })?;
        Ok(Self {
            token: token.to_string(),
            token_hash: GitHubCache::key(&["token", token]),
            base_url: base_url.trim_end_matches('/').to_string(),
            http,
            state,
        })
    }

    pub(crate) fn data_revision() -> u64 {
        global_state().data_revision()
    }

    pub(crate) fn data_changes() -> broadcast::Receiver<super::GitHubDataChange> {
        global_state().data_changes()
    }

    pub(crate) async fn status() -> super::types::GitHubApiStatus {
        let state = global_state();
        state
            .recorder
            .status(&state.budget, state.data_revision())
            .await
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
            .execute_json_with_mutation_boundary(Method::POST, "/graphql", Some(body), descriptor)
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
            .execute_json_with_mutation_boundary(Method::POST, "/graphql", Some(body), descriptor)
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
            .execute_json_with_mutation_boundary(method, route.as_ref(), body, descriptor)
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

    pub(super) async fn execute_json(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
        mutation_guard: &mut Option<GitHubMutationGuard>,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        if descriptor.priority.is_write() {
            let data_revision = self.state.data_revision();
            return self
                .execute_json_at_revision(
                    method,
                    route,
                    body,
                    descriptor,
                    data_revision,
                    mutation_guard,
                )
                .await;
        }
        let operation = descriptor.operation.clone();
        retry_stable_read(&operation, |data_revision| {
            let method = method.clone();
            let body = body.clone();
            let descriptor = descriptor.clone();
            async move {
                let mut read_guard = None;
                self.execute_json_at_revision(
                    method,
                    route,
                    body,
                    descriptor,
                    data_revision,
                    &mut read_guard,
                )
                .await
            }
        })
        .await
        .map(|(response, _)| response)
    }

    async fn execute_json_at_revision(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
        data_revision: u64,
        mutation_guard: &mut Option<GitHubMutationGuard>,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        let cache_key = self.cache_key(method.as_str(), route, body.as_ref(), data_revision);
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
        let acquire = self.state.budget.acquire_for(&descriptor).await;
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
            .map_err(|error| request_error(&descriptor.operation, &error))?;
        self.handle_http_response(response, &cache_key, &descriptor, stale, mutation_guard)
            .await
            .map_err(|error| context_error(&descriptor.operation, &error))
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "the HTTP response boundary handles cache revalidation, rate limits, and mutation certainty"
    )]
    async fn handle_http_response(
        &self,
        response: reqwest::Response,
        cache_key: &str,
        descriptor: &GitHubRequestDescriptor,
        stale: Option<super::cache::GitHubCacheHit>,
        mutation_guard: &mut Option<GitHubMutationGuard>,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        let status = response.status();
        let headers = response.headers().clone();
        if status.is_success() {
            mark_remote_success(mutation_guard);
        }
        let snapshot = self.state.budget.observe_headers(&headers).await;
        if descriptor.resource != GitHubRateResource::Graphql {
            self.state
                .budget
                .observe_operation_cost(descriptor, observed_rest_cost(status))
                .await;
        }
        if status == StatusCode::NOT_MODIFIED
            && let Some(hit) = stale
        {
            self.state.cache.store(
                cache_key,
                &hit.body,
                hit.etag.clone(),
                descriptor.cache_policy,
            );
            return Ok(revalidated_response(hit.body, snapshot));
        }
        self.observe_secondary_limit_if_throttled(status, &headers, snapshot.as_ref())
            .await;
        let text = response.text().await.map_err(|error| {
            CliErrorKind::workflow_io(format!("read github response body: {error}"))
        })?;
        if !status.is_success() {
            return Err(http_status_error(status, &text));
        }
        self.finalize_success_response(
            cache_key,
            descriptor,
            &headers,
            status,
            &text,
            snapshot,
            mutation_guard,
        )
        .await
    }

    async fn observe_secondary_limit_if_throttled(
        &self,
        status: StatusCode,
        headers: &HeaderMap,
        snapshot: Option<&GitHubRateLimitSnapshot>,
    ) {
        if matches!(status.as_u16(), 403 | 429) {
            self.state
                .budget
                .observe_secondary_limit(
                    snapshot.map_or(GitHubRateResource::Core, |snapshot| snapshot.resource),
                    parse_retry_after(headers),
                )
                .await;
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "the finalizer needs the exact response and cache context without cloning bodies"
    )]
    async fn finalize_success_response(
        &self,
        cache_key: &str,
        descriptor: &GitHubRequestDescriptor,
        headers: &HeaderMap,
        status: StatusCode,
        text: &str,
        snapshot: Option<GitHubRateLimitSnapshot>,
        mutation_guard: &mut Option<GitHubMutationGuard>,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        let body: Value = serde_json::from_str(text)
            .map_err(|error| CliErrorKind::workflow_parse(format!("parse github json: {error}")))?;
        if descriptor.resource == GitHubRateResource::Graphql && graphql_mutation_failed(&body) {
            mark_remote_failure(mutation_guard);
        }
        self.observe_graphql_body_cost(descriptor, &body).await;
        let etag = headers
            .get(ETAG)
            .and_then(|value| value.to_str().ok())
            .map(ToString::to_string);
        self.state
            .cache
            .store(cache_key, &body, etag, descriptor.cache_policy);
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

    async fn observe_graphql_body_cost(&self, descriptor: &GitHubRequestDescriptor, body: &Value) {
        if descriptor.resource == GitHubRateResource::Graphql
            && let Some(cost) = body
                .pointer("/data/rateLimit/cost")
                .and_then(Value::as_u64)
                .and_then(|value| u32::try_from(value).ok())
        {
            self.state
                .budget
                .observe_operation_cost(descriptor, cost)
                .await;
        }
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
        data_revision: u64,
    ) -> String {
        let body = body.map_or_else(String::new, Value::to_string);
        let data_revision = data_revision.to_string();
        let cache_scope = self.state.cache.scope();
        GitHubCache::key(&[
            cache_scope.as_str(),
            &self.token_hash,
            &self.base_url,
            method,
            route,
            body.as_str(),
            data_revision.as_str(),
        ])
    }
}

fn observed_rest_cost(status: StatusCode) -> u32 {
    u32::from(status != StatusCode::NOT_MODIFIED)
}

fn graphql_mutation_failed(body: &Value) -> bool {
    body.get("errors")
        .and_then(Value::as_array)
        .is_some_and(|errors| !errors.is_empty())
        && body.get("data").is_none_or(Value::is_null)
}

fn mark_remote_success(mutation_guard: &mut Option<GitHubMutationGuard>) {
    if let Some(guard) = mutation_guard {
        guard.mark_remote_success();
    }
}

fn mark_remote_failure(mutation_guard: &mut Option<GitHubMutationGuard>) {
    if let Some(guard) = mutation_guard {
        guard.mark_remote_failure();
    }
}
