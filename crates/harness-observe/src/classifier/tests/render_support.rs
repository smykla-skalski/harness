//! Test-only mirror of `harness::observe::output::render_json`'s JSON shape
//! (id/location/classification/source/message/remediation), scoped to the
//! fields these classifier tests assert on. The real renderer lives in the
//! root crate and pulls in SARIF/markdown rendering machinery classifier has
//! no production reason to depend on, so this reproduces just the shape
//! rather than adding a dependency edge back onto root for test-only code.

use harness_protocol::observe::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, SourceTool,
};
use serde::Serialize;

#[derive(Serialize)]
struct RenderedIssue<'a> {
    id: &'a str,
    location: Location,
    classification: Classification<'a>,
    source: Source,
    message: Message<'a>,
    remediation: Remediation<'a>,
}

#[derive(Serialize)]
struct Location {
    line: usize,
}

#[derive(Serialize)]
struct Classification<'a> {
    code: IssueCode,
    category: IssueCategory,
    severity: IssueSeverity,
    confidence: Confidence,
    fingerprint: &'a str,
}

#[derive(Serialize)]
struct Source {
    role: MessageRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool: Option<SourceTool>,
}

#[derive(Serialize)]
struct Message<'a> {
    summary: &'a str,
    details: &'a str,
}

#[derive(Serialize)]
struct Remediation<'a> {
    safety: FixSafety,
    available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<&'a str>,
}

pub(super) fn render_json(issue: &Issue) -> String {
    let rendered = RenderedIssue {
        id: &issue.id,
        location: Location { line: issue.line },
        classification: Classification {
            code: issue.code,
            category: issue.category,
            severity: issue.severity,
            confidence: issue.confidence,
            fingerprint: &issue.fingerprint,
        },
        source: Source {
            role: issue.source_role,
            tool: issue.source_tool,
        },
        message: Message {
            summary: &issue.summary,
            details: &issue.details,
        },
        remediation: Remediation {
            safety: issue.fix_safety,
            available: issue.fix_safety.is_fixable(),
            target: issue.fix_target.as_deref(),
            hint: issue.fix_hint.as_deref(),
        },
    };
    serde_json::to_string(&rendered).expect("valid JSON serialization")
}
