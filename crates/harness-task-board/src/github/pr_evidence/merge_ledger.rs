use std::future::Future;

use harness_kernel::errors::{CliError, CliErrorKind};

use super::action_ledger::{
    ActionAdmission, ActionOutcome, PullRequestAction, PullRequestActionKind,
    PullRequestActionStore, action_effect_observed, begin_action, finish_action, reconcile_action,
};
use super::{PullRequestEvidenceSource, PullRequestIdentity};

/// The terminal disposition of running a merge through the durable ledger.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeLedgerOutcome {
    /// The merge request was issued this call and succeeded.
    Merged,
    /// A prior attempt already merged the pull request; nothing was re-issued.
    AlreadyApplied,
    /// A prior attempt failed permanently; the merge was not retried.
    Abandoned,
}

/// Run a merge through the durable action ledger so a restart never issues a
/// second merge for the same intent.
///
/// `begin_action` records the intent before GitHub sees it. An intent that
/// already succeeded is `AlreadyApplied`; a permanently-failed one is
/// `Abandoned`; an uncertain prior attempt is reconciled against fresh evidence
/// (a pull request already `Merged` is adopted as applied) before any retry.
/// Only on a clean `Proceed` is `merge` invoked, and its result is recorded:
/// success finalizes the record, while any error is stored as `Uncertain`, since
/// a merge request that errored may still have applied server-side, so the next
/// attempt reconciles rather than blindly re-issuing a possibly-duplicate merge.
///
/// # Errors
/// Propagates a storage error, or the merge's own error after it has been
/// recorded as uncertain.
pub async fn merge_with_ledger<M, MFut>(
    store: &dyn PullRequestActionStore,
    source: &dyn PullRequestEvidenceSource,
    action: PullRequestAction,
    merge: M,
) -> Result<MergeLedgerOutcome, CliError>
where
    M: FnOnce() -> MFut,
    MFut: Future<Output = Result<(), CliError>>,
{
    match begin_action(store, action.clone()).await? {
        ActionAdmission::AlreadyApplied => Ok(MergeLedgerOutcome::AlreadyApplied),
        ActionAdmission::Abandoned => Ok(MergeLedgerOutcome::Abandoned),
        ActionAdmission::Proceed => issue_merge(store, &action.id, merge).await,
        ActionAdmission::NeedsReconcile => {
            if reconcile_merge(store, source, &action).await? {
                Ok(MergeLedgerOutcome::AlreadyApplied)
            } else {
                issue_merge(store, &action.id, merge).await
            }
        }
    }
}

/// Resolve an uncertain merge against fresh evidence, returning whether the pull
/// request already reads back as `Merged`.
async fn reconcile_merge(
    store: &dyn PullRequestActionStore,
    source: &dyn PullRequestEvidenceSource,
    action: &PullRequestAction,
) -> Result<bool, CliError> {
    let observed = merge_effect_observed(source, &action.identity).await?;
    match reconcile_action(store, action.clone(), observed).await? {
        ActionAdmission::AlreadyApplied => Ok(true),
        ActionAdmission::Proceed => Ok(false),
        other => Err(CliErrorKind::workflow_io(format!(
            "unexpected admission reconciling merge {}: {other:?}",
            action.id
        ))
        .into()),
    }
}

async fn merge_effect_observed(
    source: &dyn PullRequestEvidenceSource,
    identity: &PullRequestIdentity,
) -> Result<bool, CliError> {
    let read = source.read_pull_request_evidence(identity).await?;
    Ok(read
        .evidence()
        .and_then(|evidence| action_effect_observed(PullRequestActionKind::Merge, evidence))
        .unwrap_or(false))
}

async fn issue_merge<M, MFut>(
    store: &dyn PullRequestActionStore,
    id: &str,
    merge: M,
) -> Result<MergeLedgerOutcome, CliError>
where
    M: FnOnce() -> MFut,
    MFut: Future<Output = Result<(), CliError>>,
{
    match merge().await {
        Ok(()) => {
            finish_action(store, id, ActionOutcome::Succeeded).await?;
            Ok(MergeLedgerOutcome::Merged)
        }
        Err(error) => {
            finish_action(
                store,
                id,
                ActionOutcome::Uncertain {
                    detail: error.to_string(),
                },
            )
            .await?;
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests;
