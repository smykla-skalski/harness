use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::time::sleep;

use harness_kernel::errors::CliError;

use super::{
    PullRequestEvidence, PullRequestEvidenceRead, PullRequestEvidenceSource, PullRequestIdentity,
};

/// A CI wait bound to one pull request head.
///
/// The wait records the pull request, the exact head revision it started on, and
/// the required checks it is waiting for. Only results observed on that same head
/// can advance it, so a status update from an older or newer revision can never
/// wake the wait onto unrelated evidence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckWait {
    pub identity: PullRequestIdentity,
    pub head_revision: String,
    pub required_checks: Vec<String>,
}

impl CheckWait {
    /// Bind a wait to the head and required checks of an observed evidence
    /// snapshot.
    #[must_use]
    pub fn for_head(evidence: &PullRequestEvidence) -> Self {
        Self {
            identity: evidence.identity.clone(),
            head_revision: evidence.head_revision.clone(),
            required_checks: evidence.gates.required_check_names.clone(),
        }
    }

    /// Decide what a fresh read means for this wait, without advancing time.
    ///
    /// A read on a different head is `Superseded` and never `Completed`, so a
    /// head change can never look like a finished wait for the old revision.
    #[must_use]
    pub fn assess(&self, read: &PullRequestEvidenceRead) -> CheckWaitProgress {
        let evidence = match read {
            PullRequestEvidenceRead::Missing { .. } => return CheckWaitProgress::Vanished,
            PullRequestEvidenceRead::Found(evidence) => evidence,
        };
        if evidence.head_revision != self.head_revision {
            return CheckWaitProgress::Superseded {
                observed_head: evidence.head_revision.clone(),
            };
        }
        if self.all_required_terminal(evidence) {
            CheckWaitProgress::Completed(evidence.clone())
        } else {
            CheckWaitProgress::Pending
        }
    }

    // A required check the head has no run for is not terminal - the wait keeps
    // waiting for it to appear and conclude rather than finishing early.
    fn all_required_terminal(&self, evidence: &PullRequestEvidence) -> bool {
        self.required_checks.iter().all(|name| {
            evidence
                .gates
                .check_state(name)
                .is_some_and(|state| !state.is_pending())
        })
    }
}

/// What one fresh read means for a [`CheckWait`], before any decision to sleep
/// or stop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckWaitProgress {
    /// Every required check reached a terminal state on the tracked head.
    Completed(Box<PullRequestEvidence>),
    /// The tracked head still has a required check pending.
    Pending,
    /// The pull request head advanced past the tracked revision.
    Superseded { observed_head: String },
    /// The pull request is no longer present.
    Vanished,
}

/// The terminal outcome of polling a [`CheckWait`]. Each distinct end state -
/// completion, a superseded head, a vanished pull request, a timeout, and a
/// cancellation - stays separable so a caller never conflates them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckWaitOutcome {
    Completed(Box<PullRequestEvidence>),
    Superseded { observed_head: String },
    Vanished,
    TimedOut,
    Cancelled,
}

/// How long to poll a [`CheckWait`] and how to interrupt it.
pub struct CheckWaitControls<'cancel> {
    /// Maximum reads before the wait times out.
    pub max_polls: u32,
    /// Delay between reads while checks are still pending.
    pub poll_interval: Duration,
    /// Set to request cancellation. It is observed at each poll boundary -
    /// before every read and before every inter-poll wait - so a flag set during
    /// a wait takes effect within one `poll_interval`.
    pub cancel: &'cancel AtomicBool,
}

/// Poll a check wait against an evidence source until it reaches a terminal
/// outcome.
///
/// Cancellation is honored at each poll boundary - before every read and before
/// every inter-poll wait - so a set flag ends the wait as `Cancelled` within one
/// `poll_interval`. Exhausting `max_polls` with checks still pending ends it as
/// `TimedOut`. A read on a new head ends it as `Superseded`, never `Completed`.
///
/// # Errors
/// Propagates a provider or transport error from the source. A pull request the
/// source reports as absent is the `Vanished` outcome, not an error.
pub async fn poll_check_wait(
    source: &dyn PullRequestEvidenceSource,
    wait: &CheckWait,
    controls: CheckWaitControls<'_>,
) -> Result<CheckWaitOutcome, CliError> {
    for attempt in 0..controls.max_polls {
        if controls.cancel.load(Ordering::Acquire) {
            return Ok(CheckWaitOutcome::Cancelled);
        }
        let read = source.read_pull_request_evidence(&wait.identity).await?;
        match wait.assess(&read) {
            CheckWaitProgress::Completed(evidence) => {
                return Ok(CheckWaitOutcome::Completed(evidence));
            }
            CheckWaitProgress::Superseded { observed_head } => {
                return Ok(CheckWaitOutcome::Superseded { observed_head });
            }
            CheckWaitProgress::Vanished => return Ok(CheckWaitOutcome::Vanished),
            CheckWaitProgress::Pending => {
                // No sleep after the final poll: the wait times out immediately
                // rather than one interval past its budget.
                if attempt + 1 < controls.max_polls {
                    if controls.cancel.load(Ordering::Acquire) {
                        return Ok(CheckWaitOutcome::Cancelled);
                    }
                    sleep(controls.poll_interval).await;
                }
            }
        }
    }
    // A set flag still wins after the budget is spent, and covers a zero-poll
    // budget whose loop body never ran.
    if controls.cancel.load(Ordering::Acquire) {
        return Ok(CheckWaitOutcome::Cancelled);
    }
    Ok(CheckWaitOutcome::TimedOut)
}

#[cfg(test)]
mod tests;
