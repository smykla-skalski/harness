use std::fmt;

use crate::observe::types::{Confidence, FixSafety, IssueCategory, IssueCode, IssueSeverity};

mod data;

use self::data::ISSUE_CODE_REGISTRY;

/// Responsibility owner for an issue code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IssueOwner {
    /// Harness CLI or infrastructure bug.
    Harness,
    /// Skill file or skill behavior defect.
    Skill,
    /// Possible upstream product bug (Kuma, CRD, webhook).
    Product,
    /// Model misbehavior (Claude, subagent).
    Model,
}

impl fmt::Display for IssueOwner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Harness => "harness",
            Self::Skill => "skill",
            Self::Product => "product",
            Self::Model => "model",
        })
    }
}

/// Static metadata for a single issue code.
#[derive(Clone, Copy)]
pub struct IssueCodeMeta {
    pub code: IssueCode,
    pub default_category: IssueCategory,
    pub default_severity: IssueSeverity,
    pub default_confidence: Confidence,
    pub default_fix_safety: FixSafety,
    pub description: &'static str,
    pub owner: IssueOwner,
}

/// Look up the static metadata for an issue code.
///
/// Returns `None` only if the code is missing from the registry (a bug).
#[must_use]
pub fn issue_code_meta(code: IssueCode) -> Option<&'static IssueCodeMeta> {
    ISSUE_CODE_REGISTRY
        .as_ref()
        .iter()
        .find(|entry| entry.code == code)
}

#[cfg(test)]
#[path = "registry/tests.rs"]
mod tests;
