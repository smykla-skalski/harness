use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::types::{ExternalRefProvider, TaskBoardItem, TaskBoardPriority};

/// Stable identity for the deterministic built-in evaluator. `#334` rule sets
/// and `#335` agent escalation are later evaluators with their own identity.
pub const BUILTIN_V1_EVALUATOR_IDENTITY: &str = "task_board.triage.builtin_v1";
/// Bumped only when this check table itself changes, never by configuration.
pub const BUILTIN_V1_EVALUATOR_VERSION: u32 = 1;

const NEEDS_INFO_LABEL: &str = "triage/needs-info";
const EXCLUSION_LABELS: [&str; 6] = [
    "duplicate",
    "invalid",
    "wontfix",
    "triage/duplicate",
    "triage/invalid",
    "triage/wontfix",
];
const FINGERPRINT_DOMAIN: &[u8] = b"harness.task_board.triage.evidence_fingerprint.v1";
const MAX_REASON_DETAIL_BYTES: usize = 256;
const MAX_EVALUATOR_IDENTITY_BYTES: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TriageVerdict {
    Todo,
    Undecided,
}

/// Closed, ordered reason codes. `NeedsInfoLabel` and `NoMeaningfulLabels` are
/// evaluated in that order before falling through to `MeaningfulLabel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TriageReasonCode {
    NeedsInfoLabel,
    NoMeaningfulLabels,
    MeaningfulLabel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TriageCause {
    Initial,
    FingerprintChanged,
    ActiveEvaluatorChanged,
}

/// The current `BuiltInV1` outcome persisted alongside a Task Board item. History
/// keeps one immutable row per generation; this is only ever the latest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardTriageDecision {
    pub verdict: TriageVerdict,
    pub reason_code: TriageReasonCode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason_detail: Option<String>,
    pub evaluator_identity: String,
    pub evaluator_version: u32,
    pub evidence_fingerprint: String,
    pub cause: TriageCause,
    pub decided_at: String,
}

/// Lower-case, trim, dedupe, and sort tags into the canonical label set `BuiltInV1`
/// evaluates and fingerprints. Order and case in the source tags never matter.
#[must_use]
pub fn canonicalize_labels(tags: &[String]) -> Vec<String> {
    let mut labels = tags
        .iter()
        .map(|tag| tag.trim().to_lowercase())
        .filter(|tag| !tag.is_empty())
        .collect::<Vec<_>>();
    labels.sort_unstable();
    labels.dedup();
    labels
}

/// Whether a canonical label is one of the closed exclusion labels (bare or
/// `triage/`-prefixed duplicate/invalid/wontfix). Callers must canonicalize first.
#[must_use]
pub fn is_exclusion_label(label: &str) -> bool {
    EXCLUSION_LABELS.contains(&label)
}

/// The first exclusion label present among `tags`, if any, in canonical form.
#[must_use]
pub fn matched_exclusion_label(tags: &[String]) -> Option<String> {
    canonicalize_labels(tags)
        .into_iter()
        .find(|label| is_exclusion_label(label))
}

/// Evaluate the ordered `BuiltInV1` check table against one item's current tags.
/// Callers are responsible for the eligibility gate (dispatchable kind, not
/// deleted, not yet linked, canonical status in Backlog/Todo) and for the
/// separate provider-exclusion pre-intake filter; this only decides the
/// verdict for an already-eligible, already-visible item.
#[must_use]
pub fn evaluate_builtin_v1(item: &TaskBoardItem) -> TriageOutcome {
    let labels = canonicalize_labels(&item.tags);
    if labels.iter().any(|label| label == NEEDS_INFO_LABEL) {
        return TriageOutcome {
            verdict: TriageVerdict::Undecided,
            reason_code: TriageReasonCode::NeedsInfoLabel,
            reason_detail: Some(NEEDS_INFO_LABEL.to_string()),
        };
    }
    if labels.is_empty() {
        return TriageOutcome {
            verdict: TriageVerdict::Undecided,
            reason_code: TriageReasonCode::NoMeaningfulLabels,
            reason_detail: None,
        };
    }
    TriageOutcome {
        verdict: TriageVerdict::Todo,
        reason_code: TriageReasonCode::MeaningfulLabel,
        reason_detail: None,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TriageOutcome {
    pub verdict: TriageVerdict,
    pub reason_code: TriageReasonCode,
    pub reason_detail: Option<String>,
}

/// Canonical evidence fingerprint over every stable, relevant fact: title,
/// body, priority, canonical labels, kind, execution repository, project id,
/// target project types, provider origin, and external reference identity.
/// Deliberately excludes volatile timestamps, revisions, workflow/session
/// lifecycle state, usage, lane placement, and planning approval, none of
/// which `BuiltInV1` (or a later evaluator reusing this fingerprint) should
/// retrigger on.
#[must_use]
pub fn evidence_fingerprint(item: &TaskBoardItem) -> String {
    let mut digest = Sha256::new();
    append_hash_part(&mut digest, FINGERPRINT_DOMAIN);
    append_hash_part(&mut digest, item.title.trim().as_bytes());
    append_hash_part(&mut digest, item.body.trim().as_bytes());
    append_hash_part(&mut digest, priority_tag(item.priority));
    for label in canonicalize_labels(&item.tags) {
        append_hash_part(&mut digest, label.as_bytes());
    }
    append_hash_part(&mut digest, item.kind.as_wire_str().as_bytes());
    append_optional_hash_part(&mut digest, item.execution_repository.as_deref());
    append_optional_hash_part(&mut digest, item.project_id.as_deref());
    let mut target_types = item.target_project_types.clone();
    target_types.sort_unstable();
    target_types.dedup();
    for target_type in &target_types {
        append_hash_part(&mut digest, target_type.as_bytes());
    }
    append_optional_hash_part(
        &mut digest,
        item.imported_from_provider.map(provider_tag_str),
    );
    let mut refs = item
        .external_refs
        .iter()
        .map(|reference| {
            format!(
                "{}#{}",
                provider_tag_str(reference.provider),
                reference.external_id
            )
        })
        .collect::<Vec<_>>();
    refs.sort_unstable();
    refs.dedup();
    for reference in &refs {
        append_hash_part(&mut digest, reference.as_bytes());
    }
    format!("sha256:{}", hex::encode(digest.finalize()))
}

/// Whether `value` has the exact `sha256:<64 lowercase hex>` shape this module
/// always produces. Used at persistence trust boundaries so a malformed
/// fingerprint is rejected before it ever reaches SQL.
#[must_use]
pub fn is_canonical_evidence_fingerprint(value: &str) -> bool {
    value.strip_prefix("sha256:").is_some_and(|digest| {
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

/// Whether `value` is a non-empty, bounded, control-character-free identity or
/// reason-detail string, for validation at persistence trust boundaries.
#[must_use]
pub fn is_canonical_bounded_text(value: &str, max_bytes: usize) -> bool {
    !value.trim().is_empty() && value.len() <= max_bytes && !value.chars().any(char::is_control)
}

#[must_use]
pub fn is_canonical_evaluator_identity(value: &str) -> bool {
    is_canonical_bounded_text(value, MAX_EVALUATOR_IDENTITY_BYTES)
}

#[must_use]
pub fn is_canonical_reason_detail(value: &str) -> bool {
    is_canonical_bounded_text(value, MAX_REASON_DETAIL_BYTES)
}

/// Whether `value` has the exact `utc_now()` shape (`YYYY-MM-DDTHH:MM:SSZ`,
/// no fractional seconds, no non-Z offset) this module's callers always
/// stamp. Parses via RFC 3339 (rejecting impossible calendar dates and
/// out-of-range times) then requires the canonical UTC-seconds re-render to
/// match the input byte-for-byte, so an otherwise-valid but non-canonical
/// timestamp -- a `+00:00` offset, fractional seconds, a non-UTC offset --
/// is rejected without weakening the fixed wire format. Used at persistence
/// trust boundaries so a malformed stored timestamp is rejected before it is
/// trusted as a decision or supersession instant.
#[must_use]
pub fn is_canonical_decided_at(value: &str) -> bool {
    let Ok(parsed) = DateTime::parse_from_rfc3339(value) else {
        return false;
    };
    parsed.with_timezone(&Utc).format("%Y-%m-%dT%H:%M:%SZ").to_string() == value
}

const fn priority_tag(priority: TaskBoardPriority) -> &'static [u8] {
    match priority {
        TaskBoardPriority::Low => b"low",
        TaskBoardPriority::Medium => b"medium",
        TaskBoardPriority::High => b"high",
        TaskBoardPriority::Critical => b"critical",
    }
}

const fn provider_tag_str(provider: ExternalRefProvider) -> &'static str {
    match provider {
        ExternalRefProvider::GitHub => "github",
        ExternalRefProvider::Todoist => "todoist",
    }
}

fn append_hash_part(digest: &mut Sha256, value: &[u8]) {
    digest.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    digest.update(value);
}

fn append_optional_hash_part(digest: &mut Sha256, value: Option<&str>) {
    digest.update([u8::from(value.is_some())]);
    if let Some(value) = value {
        append_hash_part(digest, value.as_bytes());
    }
}

#[cfg(test)]
#[path = "triage_tests.rs"]
mod tests;
