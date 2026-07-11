use reqwest::header::HeaderMap;
use reqwest::{Method, StatusCode};
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

use super::budget::parse_retry_after;
use super::client::GitHubProtectedClient;
use super::mutation::run_detached_mutation;
use super::response::{budget_error, context_error, http_status_error, request_error};
use super::state::GitHubMutationGuard;
use super::{GitHubRateResource, GitHubRequestDescriptor};

pub(crate) struct GitHubRestRawResponse<T> {
    pub(crate) status: StatusCode,
    pub(crate) headers: HeaderMap,
    pub(crate) body: Option<T>,
}

impl GitHubProtectedClient {
    pub(crate) async fn rest_json_with_headers<T>(
        &self,
        method: Method,
        route: impl AsRef<str>,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
        extra_headers: HeaderMap,
    ) -> Result<GitHubRestRawResponse<T>, CliError>
    where
        T: DeserializeOwned + Send + 'static,
    {
        let priority = descriptor.priority;
        let route = route.as_ref().to_string();
        if priority.is_write() {
            let operation = descriptor.operation.clone();
            let client = self.clone();
            return run_detached_mutation(operation, move |guard| async move {
                let mut mutation_guard = Some(guard);
                client
                    .rest_json_with_headers_at_revision(
                        method,
                        &route,
                        body,
                        descriptor,
                        extra_headers,
                        &mut mutation_guard,
                    )
                    .await
            })
            .await;
        }

        let mut mutation_guard = None;
        loop {
            let data_revision = self.state.data_revision();
            let response = self
                .rest_json_with_headers_at_revision(
                    method.clone(),
                    &route,
                    body.clone(),
                    descriptor.clone(),
                    extra_headers.clone(),
                    &mut mutation_guard,
                )
                .await?;
            if priority.is_write() || self.state.data_revision() == data_revision {
                return Ok(response);
            }
        }
    }

    async fn rest_json_with_headers_at_revision<T>(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
        extra_headers: HeaderMap,
        mutation_guard: &mut Option<GitHubMutationGuard>,
    ) -> Result<GitHubRestRawResponse<T>, CliError>
    where
        T: DeserializeOwned,
    {
        let _permit = self
            .state
            .budget
            .acquire_for(&descriptor)
            .await
            .map_err(|error| budget_error(&descriptor.operation, error))?;
        let response = self
            .send_json_with_headers(method, route, body, extra_headers)
            .await
            .map_err(|error| request_error(&descriptor.operation, &error))?;
        let status = response.status();
        let headers = response.headers().clone();
        if status.is_success()
            && let Some(guard) = mutation_guard.as_mut()
        {
            guard.mark_remote_success();
        }
        self.observe_rest_status(&descriptor, status, &headers)
            .await;
        if status == StatusCode::NOT_MODIFIED {
            return Ok(GitHubRestRawResponse {
                status,
                headers,
                body: None,
            });
        }
        let text = response
            .text()
            .await
            .map_err(|error| request_error(&descriptor.operation, &error))?;
        if !status.is_success() {
            return Err(context_error(
                &descriptor.operation,
                &http_status_error(status, &text),
            ));
        }
        let body = serde_json::from_str(&text).map_err(|error| {
            CliErrorKind::workflow_parse(format!(
                "{}: parse github json: {error}",
                descriptor.operation
            ))
        })?;
        Ok(GitHubRestRawResponse {
            status,
            headers,
            body: Some(body),
        })
    }

    pub(crate) async fn rest_empty(
        &self,
        method: Method,
        route: impl AsRef<str>,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
    ) -> Result<(), CliError> {
        let priority = descriptor.priority;
        let route = route.as_ref().to_string();
        if priority.is_write() {
            let operation = descriptor.operation.clone();
            let client = self.clone();
            return run_detached_mutation(operation, move |guard| async move {
                let mut mutation_guard = Some(guard);
                client
                    .rest_empty_with_mutation_boundary(
                        method,
                        &route,
                        body,
                        descriptor,
                        &mut mutation_guard,
                    )
                    .await
            })
            .await;
        }

        let mut mutation_guard = None;
        self.rest_empty_with_mutation_boundary(
            method,
            &route,
            body,
            descriptor,
            &mut mutation_guard,
        )
        .await
    }

    async fn rest_empty_with_mutation_boundary(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
        mutation_guard: &mut Option<GitHubMutationGuard>,
    ) -> Result<(), CliError> {
        let _permit = self
            .state
            .budget
            .acquire_for(&descriptor)
            .await
            .map_err(|error| budget_error(&descriptor.operation, error))?;
        let response = self
            .send_json(method, route, body, None)
            .await
            .map_err(|error| request_error(&descriptor.operation, &error))?;
        let status = response.status();
        let headers = response.headers().clone();
        if status.is_success()
            && let Some(guard) = mutation_guard.as_mut()
        {
            guard.mark_remote_success();
        }
        self.observe_rest_status(&descriptor, status, &headers)
            .await;
        let text = response
            .text()
            .await
            .map_err(|error| request_error(&descriptor.operation, &error))?;
        if status.is_success() {
            return Ok(());
        }
        Err(context_error(
            &descriptor.operation,
            &http_status_error(status, &text),
        ))
    }

    async fn observe_rest_status(
        &self,
        descriptor: &GitHubRequestDescriptor,
        status: StatusCode,
        headers: &HeaderMap,
    ) {
        let snapshot = self.state.budget.observe_headers(headers).await;
        self.state
            .budget
            .observe_operation_cost(descriptor, observed_rest_cost(status))
            .await;
        if matches!(status.as_u16(), 403 | 429) {
            self.state
                .budget
                .observe_secondary_limit(
                    snapshot
                        .as_ref()
                        .map_or(GitHubRateResource::Core, |snapshot| snapshot.resource),
                    parse_retry_after(headers),
                )
                .await;
        }
        self.state.recorder.record_network(
            &descriptor.operation,
            descriptor.resource,
            descriptor.priority,
            Some(status.as_u16()),
            0,
        );
    }
}

fn observed_rest_cost(status: StatusCode) -> u32 {
    u32::from(status != StatusCode::NOT_MODIFIED)
}
