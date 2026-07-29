use std::fmt;

use harness_kernel::errors::CliError;

use super::gates::{PullRequestMergeGates, ReviewDecision};
use super::{
    PullRequestEvidence, PullRequestEvidenceRead, PullRequestEvidenceSource, PullRequestIdentity,
    PullRequestLifecycle,
};

/// Which gates a pending action requires before it may touch GitHub.
///
/// Different mutations need different gates: approving needs only an open,
/// non-draft pull request on the verified head, while merging additionally needs
/// passing checks, approvals, no conflict, and write permission.
#[expect(
    clippy::struct_excessive_bools,
    reason = "each field is an independent, orthogonal gate a caller opts into"
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActionGateRequirement {
    pub open: bool,
    pub not_draft: bool,
    pub mergeable: bool,
    pub required_checks: bool,
    pub approvals: bool,
    pub write_permission: bool,
}

impl ActionGateRequirement {
    /// Everything a merge must satisfy.
    #[must_use]
    pub fn for_merge() -> Self {
        Self {
            open: true,
            not_draft: true,
            mergeable: true,
            required_checks: true,
            approvals: true,
            write_permission: true,
        }
    }

    /// What an approval must satisfy: an open, non-draft pull request on the
    /// verified head. The approval's own checks and merge gates are the merge's
    /// concern, not the approval's.
    #[must_use]
    pub fn for_approval() -> Self {
        Self {
            open: true,
            not_draft: true,
            mergeable: false,
            required_checks: false,
            approvals: false,
            write_permission: false,
        }
    }

    /// What a comment must satisfy: nothing beyond the pull request still being
    /// present on the verified head. A comment is not a merge, so it does not
    /// require an open, mergeable, or approved state; it only refuses to post
    /// onto a vanished pull request or a moved head, which the head check in
    /// [`evaluate_action_gates`] enforces regardless of these flags.
    #[must_use]
    pub fn for_comment() -> Self {
        Self {
            open: false,
            not_draft: false,
            mergeable: false,
            required_checks: false,
            approvals: false,
            write_permission: false,
        }
    }
}

/// A single reason an action was refused. Every variant renders a clear message,
/// so a blocked action always explains itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActionGateBlock {
    PullRequestMissing,
    HeadMoved {
        expected: String,
        observed: String,
    },
    NotOpen(PullRequestLifecycle),
    Draft,
    Conflicts,
    MergeabilityUnknown,
    RequiredChecksIncomplete {
        missing: Vec<String>,
        unsatisfied: Vec<String>,
    },
    ApprovalsMissing {
        decision: ReviewDecision,
        current: u32,
        required: u32,
    },
    WritePermissionMissing,
}

impl fmt::Display for ActionGateBlock {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PullRequestMissing => write!(formatter, "pull request is no longer present"),
            Self::HeadMoved { expected, observed } => write!(
                formatter,
                "head moved from the verified {expected} to {observed}"
            ),
            Self::NotOpen(lifecycle) => {
                write!(formatter, "pull request is {lifecycle:?}, not open")
            }
            Self::Draft => write!(formatter, "pull request is a draft"),
            Self::Conflicts => write!(formatter, "pull request has merge conflicts"),
            Self::MergeabilityUnknown => {
                write!(
                    formatter,
                    "mergeability is unknown and cannot be assumed safe"
                )
            }
            Self::RequiredChecksIncomplete {
                missing,
                unsatisfied,
            } => write!(
                formatter,
                "required checks incomplete (missing: {missing:?}, not passing: {unsatisfied:?})"
            ),
            Self::ApprovalsMissing {
                decision,
                current,
                required,
            } => write!(
                formatter,
                "approvals not satisfied (decision {decision:?}, {current}/{required})"
            ),
            Self::WritePermissionMissing => {
                write!(
                    formatter,
                    "viewer cannot act on the pull request (no write access or admin merge)"
                )
            }
        }
    }
}

/// Whether an action may proceed against the freshly-read evidence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActionGateDecision {
    /// Every required gate passed on the verified head.
    Proceed(Box<PullRequestEvidence>),
    /// One or more gates blocked the action; no mutation may be issued.
    Blocked(Vec<ActionGateBlock>),
}

impl ActionGateDecision {
    #[must_use]
    pub fn is_clear(&self) -> bool {
        matches!(self, Self::Proceed(_))
    }

    #[must_use]
    pub fn blocks(&self) -> &[ActionGateBlock] {
        match self {
            Self::Proceed(_) => &[],
            Self::Blocked(blocks) => blocks,
        }
    }
}

/// Decide, from a fresh read, whether an action may proceed - without touching
/// GitHub.
///
/// The verified head must still be the current head; a moved head blocks on its
/// own, since every other gate would be judged on the wrong revision. An
/// unknown or unavailable gate blocks rather than passing, so a value that could
/// not be confirmed never reads as safe.
#[must_use]
pub fn evaluate_action_gates(
    read: &PullRequestEvidenceRead,
    verified_head: &str,
    requirement: ActionGateRequirement,
) -> ActionGateDecision {
    let evidence = match read {
        PullRequestEvidenceRead::Missing { .. } => {
            return ActionGateDecision::Blocked(vec![ActionGateBlock::PullRequestMissing]);
        }
        PullRequestEvidenceRead::Found(evidence) => evidence,
    };
    if evidence.head_revision != verified_head {
        return ActionGateDecision::Blocked(vec![ActionGateBlock::HeadMoved {
            expected: verified_head.to_string(),
            observed: evidence.head_revision.clone(),
        }]);
    }

    let blocks = collect_gate_blocks(evidence, requirement);
    if blocks.is_empty() {
        ActionGateDecision::Proceed(Box::new((**evidence).clone()))
    } else {
        ActionGateDecision::Blocked(blocks)
    }
}

fn collect_gate_blocks(
    evidence: &PullRequestEvidence,
    requirement: ActionGateRequirement,
) -> Vec<ActionGateBlock> {
    let mut blocks = lifecycle_blocks(evidence, requirement);
    blocks.extend(merge_blocks(&evidence.gates, requirement));
    blocks
}

fn lifecycle_blocks(
    evidence: &PullRequestEvidence,
    requirement: ActionGateRequirement,
) -> Vec<ActionGateBlock> {
    let mut blocks = Vec::new();
    if requirement.open && !evidence.is_open() {
        blocks.push(ActionGateBlock::NotOpen(evidence.lifecycle));
    }
    if requirement.not_draft && evidence.is_draft {
        blocks.push(ActionGateBlock::Draft);
    }
    if requirement.mergeable && !evidence.gates.is_mergeable() {
        blocks.push(if evidence.gates.has_conflicts() {
            ActionGateBlock::Conflicts
        } else {
            ActionGateBlock::MergeabilityUnknown
        });
    }
    blocks
}

fn merge_blocks(
    gates: &PullRequestMergeGates,
    requirement: ActionGateRequirement,
) -> Vec<ActionGateBlock> {
    let mut blocks = Vec::new();
    if requirement.required_checks && !gates.required_checks_satisfied() {
        blocks.push(ActionGateBlock::RequiredChecksIncomplete {
            missing: to_owned(&gates.missing_required_checks()),
            unsatisfied: to_owned(&gates.unsatisfied_required_checks()),
        });
    }
    if requirement.approvals && !gates.review.is_satisfied() {
        blocks.push(ActionGateBlock::ApprovalsMissing {
            decision: gates.review.decision,
            current: gates.review.current_approvals,
            required: gates.review.required_approvals,
        });
    }
    // A fork pull request leaves `viewer_can_update` false even for a maintainer
    // who can still merge as an admin, so either capability satisfies the gate.
    if requirement.write_permission && !(gates.viewer_can_update || gates.viewer_can_merge_as_admin)
    {
        blocks.push(ActionGateBlock::WritePermissionMissing);
    }
    blocks
}

/// Read fresh evidence and decide whether an action may proceed.
///
/// Call this immediately before every GitHub mutation and issue the mutation
/// only on [`ActionGateDecision::Proceed`]; a `Blocked` decision must produce no
/// remote request.
///
/// # Errors
/// Propagates a provider or transport error from the source. A pull request the
/// source reports as absent is a `Blocked` decision, not an error.
pub async fn verify_action_gates(
    source: &dyn PullRequestEvidenceSource,
    identity: &PullRequestIdentity,
    verified_head: &str,
    requirement: ActionGateRequirement,
) -> Result<ActionGateDecision, CliError> {
    let read = source.read_pull_request_evidence(identity).await?;
    Ok(evaluate_action_gates(&read, verified_head, requirement))
}

fn to_owned(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| (*name).to_string()).collect()
}

#[cfg(test)]
mod tests;
