use std::error::Error;
use std::fmt;
use std::future::Future;

use crate::errors::{CliError, CliErrorKind};

use super::state::global_state;

const MAX_STABLE_READ_ATTEMPTS: usize = 3;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GitHubReadStabilityError {
    operation: String,
    attempts: usize,
    final_start_revision: u64,
    final_end_revision: u64,
}

impl fmt::Display for GitHubReadStabilityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "github read '{}' did not stabilize after {} attempts; final data revision changed from {} to {}",
            self.operation, self.attempts, self.final_start_revision, self.final_end_revision
        )
    }
}

impl Error for GitHubReadStabilityError {}

impl From<GitHubReadStabilityError> for CliError {
    fn from(error: GitHubReadStabilityError) -> Self {
        CliErrorKind::concurrent_modification(error.to_string()).into()
    }
}

pub(crate) async fn retry_stable_read<T, E, Fetch, FetchFuture>(
    operation: &str,
    fetch: Fetch,
) -> Result<(T, u64), E>
where
    E: From<GitHubReadStabilityError>,
    Fetch: FnMut(u64) -> FetchFuture,
    FetchFuture: Future<Output = Result<T, E>>,
{
    retry_stable_read_with_revision(operation, fetch, || global_state().data_revision()).await
}

async fn retry_stable_read_with_revision<T, E, Fetch, FetchFuture, Revision>(
    operation: &str,
    mut fetch: Fetch,
    revision: Revision,
) -> Result<(T, u64), E>
where
    E: From<GitHubReadStabilityError>,
    Fetch: FnMut(u64) -> FetchFuture,
    FetchFuture: Future<Output = Result<T, E>>,
    Revision: Fn() -> u64,
{
    let mut final_start_revision = 0;
    let mut final_end_revision = 0;
    for _ in 0..MAX_STABLE_READ_ATTEMPTS {
        final_start_revision = revision();
        let value = fetch(final_start_revision).await?;
        final_end_revision = revision();
        if final_end_revision == final_start_revision {
            return Ok((value, final_start_revision));
        }
    }
    Err(GitHubReadStabilityError {
        operation: operation.to_string(),
        attempts: MAX_STABLE_READ_ATTEMPTS,
        final_start_revision,
        final_end_revision,
    }
    .into())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

    use super::*;

    #[derive(Debug, Eq, PartialEq)]
    enum TestError {
        Source,
        Unstable(GitHubReadStabilityError),
    }

    impl From<GitHubReadStabilityError> for TestError {
        fn from(error: GitHubReadStabilityError) -> Self {
            Self::Unstable(error)
        }
    }

    #[tokio::test]
    async fn retries_until_one_attempt_uses_a_stable_revision() {
        let revisions = Arc::new(AtomicU64::new(1));
        let calls = Arc::new(AtomicUsize::new(0));
        let fetch_revisions = Arc::clone(&revisions);
        let fetch_calls = Arc::clone(&calls);
        let observed_revisions = Arc::clone(&revisions);

        let result: Result<(usize, u64), TestError> = retry_stable_read_with_revision(
            "test.eventually_stable",
            move |_| {
                let revisions = Arc::clone(&fetch_revisions);
                let calls = Arc::clone(&fetch_calls);
                async move {
                    let attempt = calls.fetch_add(1, Ordering::SeqCst) + 1;
                    if attempt < MAX_STABLE_READ_ATTEMPTS {
                        revisions.fetch_add(1, Ordering::SeqCst);
                    }
                    Ok(attempt)
                }
            },
            move || observed_revisions.load(Ordering::SeqCst),
        )
        .await;

        assert_eq!(result, Ok((MAX_STABLE_READ_ATTEMPTS, 3)));
        assert_eq!(calls.load(Ordering::SeqCst), MAX_STABLE_READ_ATTEMPTS);
    }

    #[tokio::test]
    async fn returns_a_controlled_error_after_the_retry_budget() {
        let revisions = Arc::new(AtomicU64::new(7));
        let calls = Arc::new(AtomicUsize::new(0));
        let fetch_revisions = Arc::clone(&revisions);
        let fetch_calls = Arc::clone(&calls);
        let observed_revisions = Arc::clone(&revisions);

        let result: Result<((), u64), TestError> = retry_stable_read_with_revision(
            "test.never_stable",
            move |_| {
                let revisions = Arc::clone(&fetch_revisions);
                let calls = Arc::clone(&fetch_calls);
                async move {
                    calls.fetch_add(1, Ordering::SeqCst);
                    revisions.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                }
            },
            move || observed_revisions.load(Ordering::SeqCst),
        )
        .await;

        assert_eq!(calls.load(Ordering::SeqCst), MAX_STABLE_READ_ATTEMPTS);
        assert_eq!(
            result,
            Err(TestError::Unstable(GitHubReadStabilityError {
                operation: "test.never_stable".to_string(),
                attempts: MAX_STABLE_READ_ATTEMPTS,
                final_start_revision: 9,
                final_end_revision: 10,
            }))
        );
    }

    #[tokio::test]
    async fn source_errors_return_without_retrying() {
        let calls = AtomicUsize::new(0);

        let result: Result<((), u64), TestError> = retry_stable_read_with_revision(
            "test.source_error",
            |_| async {
                calls.fetch_add(1, Ordering::SeqCst);
                Err(TestError::Source)
            },
            || 1,
        )
        .await;

        assert_eq!(result, Err(TestError::Source));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn instability_maps_to_the_concurrent_workflow_error() {
        let error = GitHubReadStabilityError {
            operation: "test.concurrent".to_string(),
            attempts: MAX_STABLE_READ_ATTEMPTS,
            final_start_revision: 4,
            final_end_revision: 5,
        };

        let cli_error = CliError::from(error);

        assert_eq!(cli_error.code(), "WORKFLOW_CONCURRENT");
    }
}
