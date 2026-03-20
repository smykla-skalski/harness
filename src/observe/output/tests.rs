use serde::Deserialize;

use super::*;

#[derive(Deserialize)]
struct ParsedIssue {
    id: String,
    location: ParsedLocation,
    classification: ParsedClassification,
    source: ParsedSource,
    message: ParsedMessage,
    remediation: ParsedRemediation,
}

#[derive(Deserialize)]
struct ParsedLocation {
    line: usize,
}

#[derive(Deserialize)]
struct ParsedClassification {
    code: String,
    category: String,
    severity: String,
    confidence: String,
    fingerprint: String,
}

#[derive(Deserialize)]
struct ParsedSource {
    role: String,
    tool: Option<String>,
}

#[derive(Deserialize)]
struct ParsedMessage {
    summary: String,
    details: String,
    evidence_excerpt: Option<String>,
}

#[derive(Deserialize)]
struct ParsedRemediation {
    safety: String,
    available: bool,
    target: Option<String>,
    hint: Option<String>,
}

#[derive(Deserialize)]
struct ParsedSummary {
    status: String,
    cursor: ParsedCursor,
    issues: ParsedIssueSummary,
}

#[derive(Deserialize)]
struct ParsedCursor {
    last_line: usize,
}

#[derive(Deserialize)]
struct ParsedIssueSummary {
    total: usize,
    by_severity: Vec<ParsedSeverityCount>,
    by_category: Vec<ParsedCategoryCount>,
}

#[derive(Deserialize)]
struct ParsedSeverityCount {
    severity: String,
    count: usize,
}

#[derive(Deserialize)]
struct ParsedCategoryCount {
    category: String,
    count: usize,
}

#[derive(Deserialize)]
struct ParsedTopCauses {
    causes: Vec<ParsedTopCause>,
}

#[derive(Deserialize)]
struct ParsedTopCause {
    code: String,
    occurrences: usize,
    summary: String,
}

fn sample_issue() -> Issue {
    Issue {
        id: "abc123def456".into(),
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

fn parse_issue_json(issue: &Issue) -> ParsedIssue {
    serde_json::from_str(&render_json(issue)).unwrap()
}

fn parse_summary_json(issues: &[Issue], last_line: usize) -> ParsedSummary {
    serde_json::from_str(&render_summary(issues, last_line)).unwrap()
}

fn parse_top_causes_json(issues: &[Issue], top_n: usize) -> ParsedTopCauses {
    serde_json::from_str(&render_top_causes(issues, top_n)).unwrap()
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
    let parsed = parse_issue_json(&issue);
    assert_eq!(parsed.message.details.len(), DETAIL_TRUNCATE_LENGTH);
}

#[test]
fn json_output_uses_nested_contract() {
    let parsed = parse_issue_json(&sample_issue());
    assert_issue_identity(&parsed);
    assert_issue_classification(&parsed);
    assert_issue_source_and_message(&parsed);
    assert_issue_remediation(&parsed);
}

#[test]
fn json_output_remediation_availability_tracks_fix_safety() {
    let mut issue = sample_issue();
    issue.fix_safety = FixSafety::TriageRequired;
    assert!(!parse_issue_json(&issue).remediation.available);

    issue.fix_safety = FixSafety::AutoFixGuarded;
    assert!(parse_issue_json(&issue).remediation.available);
}

#[test]
fn json_output_source_tool() {
    let mut issue = sample_issue();
    issue.source_tool = Some(SourceTool::Bash);
    assert_eq!(
        parse_issue_json(&issue).source.tool.as_deref(),
        Some("Bash")
    );
}

#[test]
fn summary_counts_use_typed_arrays() {
    let parsed = parse_summary_json(&[sample_issue(), sample_issue()], 100);
    assert_summary_cursor(&parsed);
    assert_summary_severity_counts(&parsed);
    assert_summary_category_counts(&parsed);
}

#[test]
fn summary_empty_issues() {
    let parsed = parse_summary_json(&[], 0);
    assert_eq!(parsed.issues.total, 0);
    assert!(parsed.issues.by_category.is_empty());
    assert!(parsed.issues.by_severity.is_empty());
}

#[test]
fn top_causes_output_uses_typed_entries() {
    let issues = vec![sample_issue(), sample_issue()];
    let parsed = parse_top_causes_json(&issues, 2);
    assert_eq!(parsed.causes.len(), 1);
    assert_eq!(parsed.causes[0].code, "build_or_lint_failure");
    assert_eq!(parsed.causes[0].occurrences, 2);
    assert_eq!(parsed.causes[0].summary, "Build failed");
}

fn assert_issue_identity(parsed: &ParsedIssue) {
    assert_eq!(parsed.id, "abc123def456");
    assert_eq!(parsed.location.line, 42);
}

fn assert_issue_classification(parsed: &ParsedIssue) {
    assert_eq!(parsed.classification.code, "build_or_lint_failure");
    assert_eq!(parsed.classification.category, "build_error");
    assert_eq!(parsed.classification.severity, "critical");
    assert_eq!(parsed.classification.confidence, "high");
    assert_eq!(parsed.classification.fingerprint, "build_or_lint_failure");
}

fn assert_issue_source_and_message(parsed: &ParsedIssue) {
    assert_eq!(parsed.source.role, "assistant");
    assert!(parsed.source.tool.is_none());
    assert_eq!(parsed.message.summary, "Build failed");
    assert!(parsed.message.evidence_excerpt.is_none());
}

fn assert_issue_remediation(parsed: &ParsedIssue) {
    assert_eq!(parsed.remediation.safety, "auto_fix_safe");
    assert!(parsed.remediation.available);
    assert_eq!(parsed.remediation.target.as_deref(), Some("src/main.rs"));
    assert_eq!(
        parsed.remediation.hint.as_deref(),
        Some("Fix the type mismatch")
    );
}

fn assert_summary_cursor(parsed: &ParsedSummary) {
    assert_eq!(parsed.status, "done");
    assert_eq!(parsed.cursor.last_line, 100);
    assert_eq!(parsed.issues.total, 2);
}

fn assert_summary_severity_counts(parsed: &ParsedSummary) {
    assert_eq!(parsed.issues.by_severity.len(), 1);
    assert_eq!(parsed.issues.by_severity[0].severity, "critical");
    assert_eq!(parsed.issues.by_severity[0].count, 2);
}

fn assert_summary_category_counts(parsed: &ParsedSummary) {
    assert_eq!(parsed.issues.by_category.len(), 1);
    assert_eq!(parsed.issues.by_category[0].category, "build_error");
    assert_eq!(parsed.issues.by_category[0].count, 2);
}
