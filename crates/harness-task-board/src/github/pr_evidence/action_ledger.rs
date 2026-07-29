use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use async_trait::async_trait;

use harness_kernel::errors::{CliError, CliErrorKind};

use super::{PullRequestEvidence, PullRequestIdentity, PullRequestLifecycle};

/// The kind of remote action a record tracks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRequestActionKind {
    Approve,
    Merge,
    Comment,
}

/// Whether a failure may be retried.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullRequestActionFailureClass {
    /// A network blip or rate limit - the same intent may be retried.
    Transient,
    /// A rejected or invalid request - retrying cannot help.
    Permanent,
}

/// The result a caller reports back to [`finish_action`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActionOutcome {
    /// The remote request completed and was applied.
    Succeeded,
    /// The remote request failed with a known class.
    Failed {
        class: PullRequestActionFailureClass,
        detail: String,
    },
    /// The result is unknown - a timeout or dropped connection after the server
    /// may already have applied the action. The record moves to `Uncertain` and
    /// must be reconciled before any retry, never blindly retried as a failure.
    Uncertain { detail: String },
}

/// The visible state of a durably-recorded action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionState {
    /// Recorded, but the remote request is not yet confirmed.
    Pending,
    /// A prior attempt may have reached GitHub; the effect must be reconciled
    /// before another attempt.
    Uncertain,
    Succeeded,
    Failed(PullRequestActionFailureClass),
}

/// A remote action's durable identity, written before GitHub ever sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PullRequestAction {
    /// Stable idempotency key. The same intent always carries the same id, so a
    /// repeat can never become a second visible action.
    pub id: String,
    pub kind: PullRequestActionKind,
    pub identity: PullRequestIdentity,
    /// The head the action was verified against.
    pub head_revision: String,
}

/// A recorded action and its current state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedAction {
    pub action: PullRequestAction,
    pub state: ActionState,
    pub detail: Option<String>,
}

impl RecordedAction {
    fn in_state(action: PullRequestAction, state: ActionState) -> Self {
        Self {
            action,
            state,
            detail: None,
        }
    }
}

/// What a caller should do with an action right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionAdmission {
    /// Safe to issue the remote request now.
    Proceed,
    /// A prior attempt is uncertain; reconcile its effect before retrying.
    NeedsReconcile,
    /// A prior attempt already succeeded; issue nothing.
    AlreadyApplied,
    /// A prior attempt failed permanently; give up.
    Abandoned,
}

/// A durable store of action records.
#[async_trait]
pub trait PullRequestActionStore: Send + Sync {
    /// Load a record by id.
    ///
    /// # Errors
    /// Returns a storage error.
    async fn load(&self, id: &str) -> Result<Option<RecordedAction>, CliError>;

    /// Insert or replace a record.
    ///
    /// # Errors
    /// Returns a storage error.
    async fn upsert(&self, record: RecordedAction) -> Result<(), CliError>;
}

/// Admit an action, recording its durable identity before GitHub sees it.
///
/// A fresh intent is recorded `Pending` and proceeds. A previously-succeeded
/// intent is `AlreadyApplied` so it never runs twice; a permanently-failed one
/// is `Abandoned`. A `Pending` or `Uncertain` record means a prior attempt may
/// have reached GitHub, so it is marked `Uncertain` and must be reconciled
/// before any retry. A transiently-failed record is reset and retried.
///
/// Admission is a load-then-upsert, not atomic on its own: two callers racing on
/// the same id could both be admitted. The store must serialize admission per id
/// - a durable implementation with a transaction or a unique constraint on the
///   active record, mirroring the task-board dispatch ledger.
///
/// # Errors
/// Returns a storage error.
pub async fn begin_action(
    store: &dyn PullRequestActionStore,
    action: PullRequestAction,
) -> Result<ActionAdmission, CliError> {
    match store.load(&action.id).await? {
        None => {
            store
                .upsert(RecordedAction::in_state(action, ActionState::Pending))
                .await?;
            Ok(ActionAdmission::Proceed)
        }
        Some(existing) => {
            ensure_same_action(&existing, &action)?;
            match existing.state {
                ActionState::Succeeded => Ok(ActionAdmission::AlreadyApplied),
                ActionState::Failed(PullRequestActionFailureClass::Permanent) => {
                    Ok(ActionAdmission::Abandoned)
                }
                ActionState::Failed(PullRequestActionFailureClass::Transient) => {
                    let stored = retained_action(existing.action, &action);
                    store
                        .upsert(RecordedAction::in_state(stored, ActionState::Pending))
                        .await?;
                    Ok(ActionAdmission::Proceed)
                }
                ActionState::Pending | ActionState::Uncertain => {
                    // Keep any recorded detail (e.g. the timeout that made a
                    // finish uncertain) so the reason reconciliation is required
                    // survives the retry.
                    store
                        .upsert(RecordedAction {
                            action: retained_action(existing.action, &action),
                            state: ActionState::Uncertain,
                            detail: existing.detail,
                        })
                        .await?;
                    Ok(ActionAdmission::NeedsReconcile)
                }
            }
        }
    }
}

/// A recorded id must always name the same intent. A caller reusing an id for a
/// different kind, target, or head is a bug the ledger surfaces rather than
/// silently treating as the same action.
fn ensure_same_action(
    existing: &RecordedAction,
    action: &PullRequestAction,
) -> Result<(), CliError> {
    // Compare intent (kind, repository, number, head), not the optional url,
    // which is metadata a retry may attach or omit without changing the action.
    let recorded = &existing.action;
    let same_intent = recorded.kind == action.kind
        && recorded.identity.repository == action.identity.repository
        && recorded.identity.number == action.identity.number
        && recorded.head_revision == action.head_revision;
    if same_intent {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "pull request action id reused for a different intent: {}",
        action.id
    ))
    .into())
}

/// Keep the durably-recorded action across a retry, adopting a url only when the
/// stored record lacks one. The url is metadata, not intent, so a retry that
/// omits it must never erase a previously-recorded url.
fn retained_action(
    mut stored: PullRequestAction,
    incoming: &PullRequestAction,
) -> PullRequestAction {
    if stored.identity.url.is_none() {
        stored.identity.url.clone_from(&incoming.identity.url);
    }
    stored
}

/// Resolve an uncertain action against observed reality. When the effect is
/// already visible the action is `AlreadyApplied` and never re-issued; otherwise
/// it resets to `Pending` and may proceed.
///
/// # Errors
/// Returns a storage error, an error when the action was never recorded or names
/// a different intent, or an error when the record is not awaiting
/// reconciliation.
pub async fn reconcile_action(
    store: &dyn PullRequestActionStore,
    action: PullRequestAction,
    effect_observed: bool,
) -> Result<ActionAdmission, CliError> {
    let Some(existing) = store.load(&action.id).await? else {
        return Err(unrecorded_action_error(&action.id));
    };
    ensure_same_action(&existing, &action)?;
    if existing.state != ActionState::Uncertain {
        return Err(CliErrorKind::workflow_io(format!(
            "pull request action is not awaiting reconciliation: {}",
            action.id
        ))
        .into());
    }
    let stored = retained_action(existing.action, &action);
    if effect_observed {
        store
            .upsert(RecordedAction::in_state(stored, ActionState::Succeeded))
            .await?;
        Ok(ActionAdmission::AlreadyApplied)
    } else {
        store
            .upsert(RecordedAction::in_state(stored, ActionState::Pending))
            .await?;
        Ok(ActionAdmission::Proceed)
    }
}

/// Record the outcome of an issued action. Success marks it `Succeeded`; a
/// failure records its class so a transient failure can retry and a permanent
/// one cannot; an unknown outcome moves it to `Uncertain` so it is reconciled,
/// not blindly retried.
///
/// # Errors
/// Returns a storage error, or an error when the action was never recorded.
pub async fn finish_action(
    store: &dyn PullRequestActionStore,
    id: &str,
    outcome: ActionOutcome,
) -> Result<(), CliError> {
    let Some(mut record) = store.load(id).await? else {
        return Err(unrecorded_action_error(id));
    };
    // A succeeded or permanently-failed action is immutable; a repeated finish
    // must never re-open it.
    if matches!(
        record.state,
        ActionState::Succeeded | ActionState::Failed(PullRequestActionFailureClass::Permanent)
    ) {
        return Ok(());
    }
    match outcome {
        ActionOutcome::Succeeded => {
            record.state = ActionState::Succeeded;
            record.detail = None;
        }
        ActionOutcome::Failed { class, detail } => {
            record.state = ActionState::Failed(class);
            record.detail = Some(detail);
        }
        ActionOutcome::Uncertain { detail } => {
            record.state = ActionState::Uncertain;
            record.detail = Some(detail);
        }
    }
    store.upsert(record).await
}

fn unrecorded_action_error(id: &str) -> CliError {
    CliErrorKind::workflow_io(format!("unrecorded pull request action: {id}")).into()
}

/// Whether fresh evidence already shows an action's effect. `None` means the
/// effect is not observable from pull request evidence alone (an approval or a
/// comment), so the caller must decide how to reconcile it.
#[must_use]
pub fn action_effect_observed(
    kind: PullRequestActionKind,
    evidence: &PullRequestEvidence,
) -> Option<bool> {
    match kind {
        PullRequestActionKind::Merge => {
            Some(matches!(evidence.lifecycle, PullRequestLifecycle::Merged))
        }
        PullRequestActionKind::Approve | PullRequestActionKind::Comment => None,
    }
}

/// An in-memory [`PullRequestActionStore`] for tests.
#[derive(Default)]
pub struct InMemoryPullRequestActionStore {
    records: Mutex<HashMap<String, RecordedAction>>,
}

impl InMemoryPullRequestActionStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl PullRequestActionStore for InMemoryPullRequestActionStore {
    async fn load(&self, id: &str) -> Result<Option<RecordedAction>, CliError> {
        // Recover the guard on poison rather than panicking: a test panic while
        // holding the lock must not cascade into unrelated failures.
        Ok(self
            .records
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(id)
            .cloned())
    }

    async fn upsert(&self, record: RecordedAction) -> Result<(), CliError> {
        self.records
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(record.action.id.clone(), record);
        Ok(())
    }
}

#[cfg(test)]
mod tests;
