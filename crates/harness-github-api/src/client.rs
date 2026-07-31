use std::sync::Arc;

use reqwest::Method;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::sync::broadcast;

use harness_kernel::errors::{CliError, CliErrorKind};

use super::budget::parse_graphql_reset_at;
use super::response::{
    GitHubApiResponse, ensure_graphql_ok, graphql_data, provenance_with_snapshot, value_u32,
};
use super::state::{GitHubApiState, GitHubMutationGuard, global_state};
use super::{
    GitHubCache, GitHubPriority, GitHubRateLimitSnapshot, GitHubRateResource,
    GitHubRequestDescriptor, retry_stable_read,
};

const DEFAULT_BASE_URL: &str = "https://api.github.com";
#[derive(Clone)]
pub struct GitHubProtectedClient {
    pub(super) token: String,
    token_hash: String,
    pub(super) base_url: String,
    pub(super) http: reqwest::Client,
    pub(super) state: Arc<GitHubApiState>,
}

impl GitHubProtectedClient {
    /// Build a client against the real GitHub API.
    ///
    /// # Errors
    /// Returns an error when `token` is empty or the shared HTTP client
    /// failed to build.
    pub fn new(token: &str) -> Result<Self, CliError> {
        Self::with_base_url(token, DEFAULT_BASE_URL)
    }

    /// Build a client against an arbitrary base URL, bypassing the real
    /// GitHub API. Exists so other crates in the workspace can drive this
    /// client against a mock HTTP server in their own tests, the same way
    /// this crate's own tests do.
    ///
    /// # Errors
    /// Returns an error when `token` is empty or the shared HTTP client
    /// failed to build.
    pub fn with_base_url(token: &str, base_url: &str) -> Result<Self, CliError> {
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

    #[must_use]
    pub fn data_revision() -> u64 {
        global_state().data_revision()
    }

    #[must_use]
    pub fn data_changes() -> broadcast::Receiver<super::GitHubDataChange> {
        global_state().data_changes()
    }

    pub async fn status() -> super::types::GitHubApiStatus {
        let state = global_state();
        state
            .recorder
            .status(&state.budget, state.data_revision())
            .await
    }

    /// Run a GraphQL query and decode `data` into `T`.
    ///
    /// # Errors
    /// Returns an error on transport failure, a non-success status, or a
    /// GraphQL response that can't be decoded into `T`.
    pub async fn graphql<T>(
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

    /// Run a GraphQL query and return the raw response envelope, unlike
    /// [`Self::graphql`] which decodes `data` into a caller-chosen type.
    ///
    /// # Errors
    /// Returns an error on transport failure, a non-success status, or a
    /// GraphQL response carrying only errors.
    pub async fn graphql_envelope(
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

    /// Run a GraphQL query and return its raw response envelope without
    /// rejecting partial `data` accompanied by field-scoped `errors`.
    ///
    /// Callers must inspect both fields. This is for aliased batch reads where
    /// one inaccessible resource must not discard successful sibling results.
    ///
    /// # Errors
    /// Returns an error on transport failure or a non-success HTTP status.
    pub async fn graphql_partial_envelope(
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
        Ok(GitHubApiResponse {
            body: raw.body,
            provenance: provenance_with_snapshot(raw.provenance, snapshot),
            status_code: raw.status_code,
        })
    }

    /// Run a REST request and decode the JSON body into `T`.
    ///
    /// # Errors
    /// Returns an error on transport failure, a non-success status, or a
    /// response body that can't be decoded into `T`.
    pub async fn rest_json<T>(
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

    pub(super) async fn observe_graphql_body_cost(
        &self,
        descriptor: &GitHubRequestDescriptor,
        body: &Value,
    ) {
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

    pub(super) fn cache_key(
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
