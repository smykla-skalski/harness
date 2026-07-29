use reqwest::Method;
use reqwest::StatusCode;
use reqwest::header::{ETAG, HeaderMap};
use serde_json::Value;

use harness_kernel::errors::{CliError, CliErrorKind};

use super::budget::parse_retry_after;
use super::client::GitHubProtectedClient;
use super::response::{
    GitHubApiResponse, budget_error, cache_state, context_error, http_status_error, request_error,
    revalidated_response,
};
use super::state::{GitHubMutationGuard, InflightGuard, InflightRole, register_inflight};
use super::{
    GitHubCachePolicy, GitHubRateLimitSnapshot, GitHubRateResource, GitHubRequestDescriptor,
    GitHubResponseProvenance,
};

impl GitHubProtectedClient {
    pub(super) async fn execute_json_at_revision(
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
    pub(super) async fn handle_http_response(
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

    pub(super) async fn observe_secondary_limit_if_throttled(
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
    pub(super) async fn finalize_success_response(
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

    pub(super) fn cache_response(
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

    pub(super) async fn wait_for_singleflight(
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
