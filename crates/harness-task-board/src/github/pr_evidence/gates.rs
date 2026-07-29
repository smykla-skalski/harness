use serde::{Deserialize, Serialize};

/// Whether GitHub can merge the head into the base right now.
///
/// `Unknown` is GitHub still computing mergeability, or a value it did not
/// report. It is kept explicit and never treated as mergeable, so a gate we
/// could not read is never mistaken for a passing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mergeability {
    Mergeable,
    Conflicting,
    Unknown,
}

/// The terminal-or-not state of one check on the head revision.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckState {
    /// Queued, in progress, or otherwise not yet concluded.
    Pending,
    Success,
    Failure,
    Skipped,
}

impl CheckState {
    /// A check counts as satisfied only once it has concluded successfully or
    /// was skipped. Pending and failing checks never count as safe.
    #[must_use]
    pub fn is_satisfied(self) -> bool {
        matches!(self, Self::Success | Self::Skipped)
    }

    #[must_use]
    pub fn is_pending(self) -> bool {
        matches!(self, Self::Pending)
    }
}

/// One named check observed on the head revision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckGate {
    pub name: String,
    pub state: CheckState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details_url: Option<String>,
}

/// GitHub's aggregate review decision for the pull request.
///
/// `Unknown` is a decision GitHub did not report; like the other gates it never
/// counts as an approval.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewDecision {
    Approved,
    ChangesRequested,
    ReviewRequired,
    Unknown,
}

/// Review gate: the aggregate decision plus the approval arithmetic branch
/// protection enforces.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewGate {
    pub decision: ReviewDecision,
    pub current_approvals: u32,
    pub required_approvals: u32,
}

impl ReviewGate {
    /// Approved outright, with enough current approvals to satisfy branch
    /// protection. A requested change, an unmet count, or an unreported decision
    /// all fail.
    #[must_use]
    pub fn is_satisfied(&self) -> bool {
        self.decision == ReviewDecision::Approved
            && self.current_approvals >= self.required_approvals
    }

    #[must_use]
    pub fn changes_requested(&self) -> bool {
        self.decision == ReviewDecision::ChangesRequested
    }
}

/// Every merge gate a decision reads off one pull request snapshot: draft state
/// (on the evidence), mergeability, conflicts, viewer permissions, per-check
/// results, and the review decision. An unknown or unavailable gate stays
/// explicit here and never reads back as safe.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullRequestMergeGates {
    pub mergeability: Mergeability,
    /// The viewer may push to the head branch (edit the pull request).
    pub viewer_can_update: bool,
    /// The viewer may merge past branch protection as an administrator.
    pub viewer_can_merge_as_admin: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub checks: Vec<CheckGate>,
    /// Check contexts branch protection requires before a merge.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub required_check_names: Vec<String>,
    pub review: ReviewGate,
}

impl PullRequestMergeGates {
    /// Mergeable only when GitHub says so outright - `Conflicting` and `Unknown`
    /// both read as not mergeable.
    #[must_use]
    pub fn is_mergeable(&self) -> bool {
        matches!(self.mergeability, Mergeability::Mergeable)
    }

    #[must_use]
    pub fn has_conflicts(&self) -> bool {
        matches!(self.mergeability, Mergeability::Conflicting)
    }

    #[must_use]
    pub fn mergeability_known(&self) -> bool {
        !matches!(self.mergeability, Mergeability::Unknown)
    }

    /// The observed state of a named check on the head, or `None` when the head
    /// has no run for it.
    #[must_use]
    pub fn check_state(&self, name: &str) -> Option<CheckState> {
        self.checks
            .iter()
            .find(|check| check.name == name)
            .map(|check| check.state)
    }

    /// Required checks branch protection names but the head has no run for. A
    /// required check without evidence is unknown, so it blocks rather than
    /// passes.
    #[must_use]
    pub fn missing_required_checks(&self) -> Vec<&str> {
        self.required_check_names
            .iter()
            .filter(|name| self.check_state(name).is_none())
            .map(String::as_str)
            .collect()
    }

    /// Required checks present on the head that have not concluded successfully,
    /// meaning pending or failing. Checks the head has no run for at all are
    /// reported by [`Self::missing_required_checks`] instead.
    #[must_use]
    pub fn unsatisfied_required_checks(&self) -> Vec<&str> {
        self.required_check_names
            .iter()
            .filter(|name| {
                self.check_state(name)
                    .is_some_and(|state| !state.is_satisfied())
            })
            .map(String::as_str)
            .collect()
    }

    /// Every required check is present and satisfied. A missing, pending, or
    /// failing required check fails the gate.
    #[must_use]
    pub fn required_checks_satisfied(&self) -> bool {
        self.required_check_names
            .iter()
            .all(|name| self.check_state(name).is_some_and(CheckState::is_satisfied))
    }
}
