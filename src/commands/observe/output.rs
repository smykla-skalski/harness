use std::collections::HashMap;
use std::fmt::Write as _;

use serde_json::json;

use super::types::Issue;

/// Maximum detail length in JSON output.
const DETAIL_TRUNCATE_LENGTH: usize = 500;

/// Render an issue as a human-readable line.
#[must_use]
pub fn render_human(issue: &Issue) -> String {
    let severity = issue.severity.to_string().to_uppercase();
    let confidence = issue.confidence.to_string();
    let mut rendered = format!(
        "[{severity}/{confidence}] L{} ({}/{}): {}",
        issue.line, issue.category, issue.code, issue.summary
    );
    if let Some(ref target) = issue.fix_target {
        let _ = write!(rendered, "\n  fix: {target}");
    }
    if let Some(ref hint) = issue.fix_hint {
        let _ = write!(rendered, "\n  hint: {hint}");
    }
    rendered
}

/// Render an issue as a JSON string with truncated details.
///
/// Builds the JSON object directly rather than serializing, modifying, and
/// re-serializing the Issue struct.
///
/// # Panics
/// Panics if the `json!()` value fails to serialize, which cannot happen
/// with valid string/integer/boolean data.
#[must_use]
pub fn render_json(issue: &Issue) -> String {
    let details: &str = if issue.details.len() > DETAIL_TRUNCATE_LENGTH {
        &issue.details[..issue.details.floor_char_boundary(DETAIL_TRUNCATE_LENGTH)]
    } else {
        &issue.details
    };

    let mut obj = json!({
        "issue_id": &issue.issue_id,
        "line": issue.line,
        "code": issue.code.to_string(),
        "category": issue.category.to_string(),
        "severity": issue.severity.to_string(),
        "confidence": issue.confidence.to_string(),
        "fix_safety": issue.fix_safety.to_string(),
        "summary": &issue.summary,
        "details": details,
        "fingerprint": &issue.fingerprint,
        "source_role": &issue.source_role,
        "fixable": issue.fix_safety.is_fixable(),
    });
    if let Some(ref tool) = issue.source_tool {
        obj["source_tool"] = json!(tool.to_string());
    }
    if let Some(ref target) = issue.fix_target {
        obj["fix_target"] = json!(target);
    }
    if let Some(ref hint) = issue.fix_hint {
        obj["fix_hint"] = json!(hint);
    }
    if let Some(ref excerpt) = issue.evidence_excerpt {
        obj["evidence_excerpt"] = json!(excerpt);
    }
    // json!() values built from valid data always serialize successfully.
    serde_json::to_string(&obj).expect("valid JSON serialization")
}

/// Render a summary JSON object with counts by severity and category.
///
/// # Panics
/// Panics if the `json!()` value fails to serialize, which cannot happen
/// with valid string/integer data.
#[must_use]
pub fn render_summary(issues: &[Issue], last_line: usize) -> String {
    let mut by_severity: HashMap<String, usize> = HashMap::new();
    let mut by_category: HashMap<String, usize> = HashMap::new();

    for issue in issues {
        *by_severity.entry(issue.severity.to_string()).or_default() += 1;
        *by_category.entry(issue.category.to_string()).or_default() += 1;
    }

    // json!() values built from valid data always serialize successfully.
    serde_json::to_string(&json!({
        "status": "done",
        "last_line": last_line,
        "total_issues": issues.len(),
        "by_severity": by_severity,
        "by_category": by_category,
    }))
    .expect("valid JSON serialization")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::observe::types::{
        Confidence, FixSafety, IssueCategory, IssueCode, IssueSeverity, MessageRole,
    };

    fn sample_issue() -> Issue {
        Issue {
            issue_id: "abc123def456".into(),
            line: 42,
            code: IssueCode::BuildOrLintFailure,
            category: IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: Confidence::High,
            fix_safety: FixSafety::AutoFixSafe,
            summary: "Build failed".into(),
            details: "error[E0308]: mismatched types".into(),
            fingerprint: "build_or_lint_failure".into(),
            source_role: MessageRole::Assistant,
            source_tool: None,
            fix_target: Some("src/main.rs".into()),
            fix_hint: Some("Fix the type mismatch".into()),
            evidence_excerpt: None,
        }
    }

    #[test]
    fn human_output_format() {
        let rendered = render_human(&sample_issue());
        assert!(rendered.starts_with("[CRITICAL/high] L42 (build_error/build_or_lint_failure):"));
        assert!(rendered.contains("fix: src/main.rs"));
        assert!(rendered.contains("hint: Fix the type mismatch"));
    }

    #[test]
    fn human_output_no_fix() {
        let mut issue = sample_issue();
        issue.fix_target = None;
        issue.fix_hint = None;
        let rendered = render_human(&issue);
        assert!(!rendered.contains("fix:"));
        assert!(!rendered.contains("hint:"));
    }

    #[test]
    fn json_output_truncates_details() {
        let mut issue = sample_issue();
        issue.details = "x".repeat(1000);
        let rendered = render_json(&issue);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        let details = parsed["details"].as_str().unwrap();
        assert_eq!(details.len(), DETAIL_TRUNCATE_LENGTH);
    }

    #[test]
    fn json_output_valid() {
        let rendered = render_json(&sample_issue());
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["line"], 42);
        assert_eq!(parsed["category"], "build_error");
        assert_eq!(parsed["severity"], "critical");
        assert_eq!(parsed["issue_id"], "abc123def456");
        assert_eq!(parsed["code"], "build_or_lint_failure");
        assert_eq!(parsed["confidence"], "high");
        assert_eq!(parsed["fix_safety"], "auto_fix_safe");
        assert_eq!(parsed["fingerprint"], "build_or_lint_failure");
        assert_eq!(parsed["fixable"], true);
    }

    #[test]
    fn json_output_fixable_backward_compat() {
        let mut issue = sample_issue();
        issue.fix_safety = FixSafety::TriageRequired;
        let rendered = render_json(&issue);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["fixable"], false);

        issue.fix_safety = FixSafety::AutoFixGuarded;
        let rendered = render_json(&issue);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["fixable"], true);
    }

    #[test]
    fn json_output_source_tool() {
        let mut issue = sample_issue();
        issue.source_tool = Some(crate::commands::observe::types::SourceTool::Bash);
        let rendered = render_json(&issue);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["source_tool"], "Bash");
    }

    #[test]
    fn json_output_no_source_tool() {
        let rendered = render_json(&sample_issue());
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert!(parsed.get("source_tool").is_none());
    }

    #[test]
    fn summary_counts() {
        let issues = vec![sample_issue(), sample_issue()];
        let rendered = render_summary(&issues, 100);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["total_issues"], 2);
        assert_eq!(parsed["last_line"], 100);
        assert_eq!(parsed["by_severity"]["critical"], 2);
        assert_eq!(parsed["by_category"]["build_error"], 2);
    }

    #[test]
    fn summary_empty_issues() {
        let rendered = render_summary(&[], 0);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["total_issues"], 0);
    }
}
