use std::future::Future;

use harness_kernel::errors::{CliError, CliErrorKind};

use super::action_ledger::{
    ActionAdmission, ActionOutcome, PullRequestAction, PullRequestActionFailureClass,
    PullRequestActionKind, PullRequestActionStore, action_effect_observed, begin_action,
    finish_action, reconcile_action,
};
use super::{
    ActionGateBlock, ActionGateDecision, ActionGateRequirement, PullRequestEvidenceSource,
    PullRequestIdentity, verify_action_gates,
};

/// The terminal disposition of running a merge through the durable ledger.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MergeLedgerOutcome {
    /// The merge request was issued this call and succeeded.
    Merged,
    /// A prior attempt already merged the pull request; nothing was re-issued.
    AlreadyApplied,
    /// The fresh gate refused the merge; no GitHub request was issued.
    Blocked(Vec<ActionGateBlock>),
}

/// Run a merge through the durable action ledger so a restart never issues a
/// second merge for the same intent, and a stale or refused merge never reaches
/// GitHub.
///
/// `begin_action` records the intent before GitHub sees it. An intent that
/// already succeeded is `AlreadyApplied`; an uncertain prior attempt is
/// reconciled against fresh evidence first (a pull request already `Merged` is
/// adopted as applied) so it is never re-merged. Only once the intent is admitted
/// does the fresh gate run: a refused gate records a transient failure and
/// returns `Blocked` without issuing any request, so a merge that never reached
/// GitHub is never left as an uncertain, reconciliation-forcing record. A cleared
/// gate issues the merge, and its own error is recorded as `Uncertain` since a
/// request that errored may still have applied server-side.
///
/// # Errors
/// Propagates a storage error, or the merge's own error after it has been
/// recorded as uncertain.
pub async fn merge_with_ledger<M, MFut>(
    store: &dyn PullRequestActionStore,
    source: &dyn PullRequestEvidenceSource,
    action: PullRequestAction,
    requirement: ActionGateRequirement,
    merge: M,
) -> Result<MergeLedgerOutcome, CliError>
where
    M: FnOnce() -> MFut,
    MFut: Future<Output = Result<(), CliError>>,
{
    match begin_action(store, action.clone()).await? {
        ActionAdmission::AlreadyApplied => Ok(MergeLedgerOutcome::AlreadyApplied),
        ActionAdmission::Abandoned => Err(CliErrorKind::workflow_io(format!(
            "merge action recorded a permanent failure and cannot be retried: {}",
            action.id
        ))
        .into()),
        ActionAdmission::Proceed => gate_then_issue(store, source, &action, requirement, merge).await,
        ActionAdmission::NeedsReconcile => {
            if reconcile_merge(store, source, &action).await? {
                Ok(MergeLedgerOutcome::AlreadyApplied)
            } else {
                gate_then_issue(store, source, &action, requirement, merge).await
            }
        }
    }
}

/// Run the fresh gate on an admitted intent and issue the merge only when it
/// clears. A refused gate records a transient failure and issues nothing.
async fn gate_then_issue<M, MFut>(
    store: &dyn PullRequestActionStore,
    source: &dyn PullRequestEvidenceSource,
    action: &PullRequestAction,
    requirement: ActionGateRequirement,
    merge: M,
) -> Result<MergeLedgerOutcome, CliError>
where
    M: FnOnce() -> MFut,
    MFut: Future<Output = Result<(), CliError>>,
{
    match verify_action_gates(source, &action.identity, &action.head_revision, requirement).await? {
        ActionGateDecision::Blocked(blocks) => {
            finish_action(
                store,
                &action.id,
                ActionOutcome::Failed {
                    class: PullRequestActionFailureClass::Transient,
                    detail: blocks_detail(&blocks),
                },
            )
            .await?;
            Ok(MergeLedgerOutcome::Blocked(blocks))
        }
        ActionGateDecision::Proceed(_) => issue_merge(store, &action.id, merge).await,
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
    Ok(matches!(
        reconcile_action(store, action.clone(), observed).await?,
        ActionAdmission::AlreadyApplied
    ))
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

fn blocks_detail(blocks: &[ActionGateBlock]) -> String {
    blocks
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("; ")
}

#[cfg(test)]
mod tests;
