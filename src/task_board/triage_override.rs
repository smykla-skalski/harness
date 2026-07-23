use serde::{Deserialize, Serialize};

use super::triage::{TaskBoardTriageDecision, TriageVerdict, is_canonical_bounded_text};

const MAX_OVERRIDE_ACTOR_BYTES: usize = 256;
const MAX_OVERRIDE_REASON_BYTES: usize = 256;

/// A durable, first-class human decision that overrides `BuiltInV1` -- or any
/// later evaluator sharing [`effective_triage_outcome`] -- for one item,
/// persisted independently of `lane_origin` provenance.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardTriageOverride {
    pub verdict: TriageVerdict,
    pub actor: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub set_at: String,
}

/// Whether `value` is a non-empty, bounded, control-character-free override
/// actor identity, for validation at persistence and transport trust
/// boundaries.
#[must_use]
pub fn is_canonical_override_actor(value: &str) -> bool {
    is_canonical_bounded_text(value, MAX_OVERRIDE_ACTOR_BYTES)
}

/// Whether `value` is a non-empty, bounded, control-character-free override
/// reason, for validation at persistence and transport trust boundaries. A
/// reason is always optional -- callers only call this when one was supplied.
#[must_use]
pub fn is_canonical_override_reason(value: &str) -> bool {
    is_canonical_bounded_text(value, MAX_OVERRIDE_REASON_BYTES)
}

/// Which side produced the [`TaskBoardTriageEffectiveOutcome`] that governs an
/// item's placement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardTriageEffectiveSource {
    Override,
    Automatic,
}

/// The verdict that actually governs an item's placement right now, and
/// which side decided it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardTriageEffectiveOutcome {
    pub verdict: TriageVerdict,
    pub source: TaskBoardTriageEffectiveSource,
}

/// The single precedence choke point for what verdict actually governs an
/// item's placement: an active override always wins over the latest
/// automatic decision. Runtime-authored rules and later agent verdicts must
/// resolve their effective placement through this function rather than
/// re-deriving their own override-vs-decision precedence, so neither can
/// bypass an active human override.
#[must_use]
pub fn effective_triage_outcome(
    override_: Option<&TaskBoardTriageOverride>,
    decision: Option<&TaskBoardTriageDecision>,
) -> Option<TaskBoardTriageEffectiveOutcome> {
    if let Some(override_) = override_ {
        return Some(TaskBoardTriageEffectiveOutcome {
            verdict: override_.verdict,
            source: TaskBoardTriageEffectiveSource::Override,
        });
    }
    decision.map(|decision| TaskBoardTriageEffectiveOutcome {
        verdict: decision.verdict,
        source: TaskBoardTriageEffectiveSource::Automatic,
    })
}

/// Whether an evaluator's placement effect must be suppressed for an item --
/// true whenever an override is active. The evaluator itself still runs and
/// may append or refresh a decision generation; only the placement side
/// effect is gated by this choke point.
#[must_use]
pub fn suppress_placement_for_override(override_: Option<&TaskBoardTriageOverride>) -> bool {
    override_.is_some()
}

#[cfg(test)]
#[path = "triage_override_tests.rs"]
mod tests;
