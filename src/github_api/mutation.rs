use std::future::Future;

use reqwest::Method;
use serde_json::Value;

use crate::errors::{CliError, CliErrorKind};

use super::client::GitHubProtectedClient;
use super::response::GitHubApiResponse;
use super::state::GitHubMutationGuard;
use super::{GitHubRequestDescriptor, begin_external_mutation};

impl GitHubProtectedClient {
    pub(super) async fn execute_json_with_mutation_boundary(
        &self,
        method: Method,
        route: &str,
        body: Option<Value>,
        descriptor: GitHubRequestDescriptor,
    ) -> Result<GitHubApiResponse<Value>, CliError> {
        if !descriptor.priority.is_write() {
            let mut mutation_guard = None;
            return self
                .execute_json(method, route, body, descriptor, &mut mutation_guard)
                .await;
        }

        let operation = descriptor.operation.clone();
        let route = route.to_string();
        let client = self.clone();
        run_detached_mutation(operation, move |guard| async move {
            let mut mutation_guard = Some(guard);
            client
                .execute_json(method, &route, body, descriptor, &mut mutation_guard)
                .await
        })
        .await
    }
}

pub(super) async fn run_detached_mutation<T, Run, RunFuture>(
    operation: String,
    run: Run,
) -> Result<T, CliError>
where
    T: Send + 'static,
    Run: FnOnce(GitHubMutationGuard) -> RunFuture + Send + 'static,
    RunFuture: Future<Output = Result<T, CliError>> + Send + 'static,
{
    tokio::spawn(async move {
        let guard = begin_external_mutation(&operation).await;
        run(guard).await
    })
    .await
    .map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "join github mutation request: {error}"
        )))
    })?
}
