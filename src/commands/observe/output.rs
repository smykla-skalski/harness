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
    let mut rendered = format!(
        "[{severity}] L{} ({}): {}",
        issue.line, issue.category, issue.summary
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
#[must_use]
pub fn render_json(issue: &Issue) -> String {
    let details: &str = if issue.details.len() > DETAIL_TRUNCATE_LENGTH {
        &issue.details[..issue.details.floor_char_boundary(DETAIL_TRUNCATE_LENGTH)]
    } else {
        &issue.details
    };

    let mut obj = json!({
        "line": issue.line,
        "category": issue.category.to_string(),
        "severity": issue.severity.to_string(),
        "summary": &issue.summary,
        "details": details,
        "source_role": &issue.source_role,
        "fixable": issue.fixable,
    });
    if let Some(ref target) = issue.fix_target {
        obj["fix_target"] = json!(target);
    }
    if let Some(ref hint) = issue.fix_hint {
        obj["fix_hint"] = json!(hint);
    }
    serde_json::to_string(&obj).unwrap_or_default()
}

/// Render a summary JSON object with counts by severity and category.
#[must_use]
pub fn render_summary(issues: &[Issue], last_line: usize) -> String {
    let mut by_severity: HashMap<String, usize> = HashMap::new();
    let mut by_category: HashMap<String, usize> = HashMap::new();

    for issue in issues {
        *by_severity.entry(issue.severity.to_string()).or_default() += 1;
        *by_category.entry(issue.category.to_string()).or_default() += 1;
    }

    serde_json::to_string(&json!({
        "status": "done",
        "last_line": last_line,
        "total_issues": issues.len(),
        "by_severity": by_severity,
        "by_category": by_category,
    }))
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::observe::types::{IssueCategory, IssueSeverity};

    fn sample_issue() -> Issue {
        Issue {
            line: 42,
            category: IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            summary: "Build failed".into(),
            details: "error[E0308]: mismatched types".into(),
            source_role: "assistant".into(),
            fixable: true,
            fix_target: Some("src/main.rs".into()),
            fix_hint: Some("Fix the type mismatch".into()),
        }
    }

    #[test]
    fn human_output_format() {
        let rendered = render_human(&sample_issue());
        assert!(rendered.starts_with("[CRITICAL] L42 (build_error): Build failed"));
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
