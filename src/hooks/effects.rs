use crate::hooks::protocol::result::NormalizedHookResult;

/// The decision a hook handler reached.
///
/// This was an ordered effect vector while the audit hook could append a second,
/// non-decision effect. That producer is gone and no other ever existed, so the
/// outcome now carries exactly the one decision it always held.
#[derive(Debug, Clone)]
pub struct HookOutcome {
    decision: NormalizedHookResult,
}

impl HookOutcome {
    #[must_use]
    pub fn allow() -> Self {
        Self::decide(NormalizedHookResult::allow())
    }

    #[must_use]
    pub fn decide(decision: NormalizedHookResult) -> Self {
        Self { decision }
    }

    #[must_use]
    pub fn decision(&self) -> &NormalizedHookResult {
        &self.decision
    }

    #[must_use]
    pub fn normalized_result(&self) -> NormalizedHookResult {
        self.decision.clone()
    }
}
