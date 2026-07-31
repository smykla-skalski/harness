use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;

use futures_util::stream::{FuturesUnordered, StreamExt as _};
use harness_kernel::errors::CliError;

use crate::external::{ExternalSyncClient, ExternalSyncOptions, TaskBoardSyncStore};

use super::super::create_recovery::ExternalCreateScopeRecovery;
use super::{BatchAccumulator, sync_scope};

const MAX_CONCURRENT_PROVIDER_SCOPES: usize = 16;

pub(super) struct ScopeWork<'a> {
    pub(super) index: usize,
    pub(super) client: &'a dyn ExternalSyncClient,
    pub(super) recovery: ExternalCreateScopeRecovery,
}

struct ScopeResult {
    index: usize,
    batch: BatchAccumulator,
    error: Option<CliError>,
}

type ScopeFuture<'a> = Pin<Box<dyn Future<Output = ScopeResult> + Send + 'a>>;

pub(super) async fn sync_scopes(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    work: Vec<ScopeWork<'_>>,
    mut combined: BatchAccumulator,
) -> Result<BatchAccumulator, CliError> {
    let mut queued = VecDeque::from(work);
    let mut pending = FuturesUnordered::new();
    fill_pending(board, options, &mut queued, &mut pending);
    let mut completed = Vec::new();
    let mut stop_launching = false;
    while let Some(result) = pending.next().await {
        stop_launching |= result.error.is_some() || result.batch.terminal_error.is_some();
        completed.push(result);
        if !stop_launching {
            fill_pending(board, options, &mut queued, &mut pending);
        }
    }
    completed.sort_by_key(|result| result.index);
    for result in completed {
        merge(&mut combined, result.batch);
        if let Some(error) = result.error {
            return Err(error);
        }
    }
    Ok(combined)
}

fn fill_pending<'a>(
    board: &'a dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    queued: &mut VecDeque<ScopeWork<'a>>,
    pending: &mut FuturesUnordered<ScopeFuture<'a>>,
) {
    while pending.len() < MAX_CONCURRENT_PROVIDER_SCOPES {
        let Some(work) = queued.pop_front() else {
            break;
        };
        pending.push(run_scope(board, options, work));
    }
}

fn run_scope<'a>(
    board: &'a dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    work: ScopeWork<'a>,
) -> ScopeFuture<'a> {
    Box::pin(async move {
        let mut batch = BatchAccumulator::default();
        let error = sync_scope(board, options, work.client, &work.recovery, &mut batch)
            .await
            .err();
        ScopeResult {
            index: work.index,
            batch,
            error,
        }
    })
}

fn merge(target: &mut BatchAccumulator, mut source: BatchAccumulator) {
    target
        .ambiguous_references
        .append(&mut source.ambiguous_references);
    target.operations.append(&mut source.operations);
    target
        .external_create_follow_ups
        .append(&mut source.external_create_follow_ups);
    target.scope_outcomes.append(&mut source.scope_outcomes);
    if target.first_provider_failure.is_none() {
        target.first_provider_failure = source.first_provider_failure;
    }
    if target.terminal_error.is_none() {
        target.terminal_error = source.terminal_error;
    }
}
