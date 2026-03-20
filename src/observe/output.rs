use std::borrow::Cow;
use std::cmp::Reverse;
use std::collections::BTreeMap;
use std::collections::HashMap;
use std::fmt::Write as _;

use serde::Serialize;
use serde_sarif::sarif::PropertyBag;

use super::types::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole,
    SourceTool,
};

/// Maximum detail length in JSON output.
const DETAIL_TRUNCATE_LENGTH: usize = 500;

#[derive(Serialize)]
struct RenderedIssue<'a> {
    issue_id: &'a str,
    line: usize,
    code: IssueCode,
    category: IssueCategory,
    severity: IssueSeverity,
    confidence: Confidence,
    fix_safety: FixSafety,
    summary: &'a str,
    details: Cow<'a, str>,
    fingerprint: &'a str,
    source_role: MessageRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    source_tool: Option<SourceTool>,
    fixable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    fix_target: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fix_hint: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    evidence_excerpt: Option<&'a str>,
}

impl<'a> From<&'a Issue> for RenderedIssue<'a> {
    fn from(issue: &'a Issue) -> Self {
        Self {
            issue_id: &issue.id,
            line: issue.line,
            code: issue.code,
            category: issue.category,
            severity: issue.severity,
            confidence: issue.confidence,
            fix_safety: issue.fix_safety,
            summary: &issue.summary,
            details: truncate_details(&issue.details),
            fingerprint: &issue.fingerprint,
            source_role: issue.source_role,
            source_tool: issue.source_tool,
            fixable: issue.fix_safety.is_fixable(),
            fix_target: issue.fix_target.as_deref(),
            fix_hint: issue.fix_hint.as_deref(),
            evidence_excerpt: issue.evidence_excerpt.as_deref(),
        }
    }
}

#[derive(Serialize)]
struct RenderedSummary {
    status: &'static str,
    last_line: usize,
    total_issues: usize,
    by_severity: BTreeMap<String, usize>,
    by_category: BTreeMap<String, usize>,
}

impl RenderedSummary {
    fn new(issues: &[Issue], last_line: usize) -> Self {
        Self {
            status: "done",
            last_line,
            total_issues: issues.len(),
            by_severity: count_by_label(issues, |issue| issue.severity.to_string()),
            by_category: count_by_label(issues, |issue| issue.category.to_string()),
        }
    }
}

#[derive(Serialize)]
struct RenderedTopCauses<'a> {
    top_causes: Vec<RenderedTopCause<'a>>,
}

impl<'a> RenderedTopCauses<'a> {
    fn new(issues: &'a [Issue], top_n: usize) -> Self {
        let mut counts: HashMap<IssueCode, RenderedTopCause<'a>> = HashMap::new();
        for issue in issues {
            let entry = counts.entry(issue.code).or_insert_with(|| RenderedTopCause {
                code: issue.code,
                count: 0,
                representative_summary: &issue.summary,
            });
            entry.count += 1;
        }

        let mut top_causes: Vec<_> = counts.into_values().collect();
        top_causes.sort_by_key(|cause| Reverse(cause.count));
        top_causes.truncate(top_n);
        Self { top_causes }
    }
}

#[derive(Serialize)]
struct RenderedTopCause<'a> {
    code: IssueCode,
    count: usize,
    representative_summary: &'a str,
}

#[derive(Serialize, tabled::Tabled)]
struct RenderedMarkdownRow {
    line: usize,
    severity: String,
    category: String,
    code: String,
    summary: String,
}

impl From<&Issue> for RenderedMarkdownRow {
    fn from(issue: &Issue) -> Self {
        Self {
            line: issue.line,
            severity: issue.severity.to_string(),
            category: issue.category.to_string(),
            code: issue.code.to_string(),
            summary: issue.summary.clone(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SarifProperties<'a> {
    category: IssueCategory,
    confidence: Confidence,
    fix_safety: FixSafety,
    issue_id: &'a str,
}

fn truncate_details(details: &str) -> Cow<'_, str> {
    if details.len() <= DETAIL_TRUNCATE_LENGTH {
        Cow::Borrowed(details)
    } else {
        let boundary = details.floor_char_boundary(DETAIL_TRUNCATE_LENGTH);
        Cow::Owned(details[..boundary].to_string())
    }
}

fn count_by_label<F>(issues: &[Issue], key: F) -> BTreeMap<String, usize>
where
    F: Fn(&Issue) -> String,
{
    let mut counts = BTreeMap::new();
    for issue in issues {
        *counts.entry(key(issue)).or_insert(0) += 1;
    }
    counts
}

fn render_json_string<T>(value: &T) -> String
where
    T: Serialize,
{
    serde_json::to_string(value).expect("valid JSON serialization")
}

fn render_json_pretty_string<T>(value: &T) -> String
where
    T: Serialize,
{
    serde_json::to_string_pretty(value).expect("valid JSON serialization")
}

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
#[must_use]
pub fn render_json(issue: &Issue) -> String {
    render_json_string(&RenderedIssue::from(issue))
}

/// Render a summary JSON object with counts by severity and category.
#[must_use]
pub fn render_summary(issues: &[Issue], last_line: usize) -> String {
    render_json_string(&RenderedSummary::new(issues, last_line))
}

/// Render issues as a markdown report using `tabled` for table formatting.
#[must_use]
pub fn render_markdown(issues: &[Issue]) -> String {
    use tabled::Table;
    use tabled::settings::Style;

    if issues.is_empty() {
        return "# Observe report\n\nNo issues found.\n".to_string();
    }

    let rows: Vec<_> = issues.iter().map(RenderedMarkdownRow::from).collect();
    let table = Table::new(&rows).with(Style::markdown()).to_string();
    let mut output = String::from("# Observe report\n\n");
    output.push_str(&table);
    let _ = write!(output, "\n\n**Total: {} issues**\n", issues.len());
    output
}

/// Render top N root causes grouped by issue code.
#[must_use]
pub fn render_top_causes(issues: &[Issue], top_n: usize) -> String {
    render_json_string(&RenderedTopCauses::new(issues, top_n))
}

/// Render issues in SARIF (Static Analysis Results Interchange Format) v2.1.0.
#[must_use]
pub fn render_sarif(issues: &[Issue]) -> String {
    use serde_sarif::sarif::{
        ArtifactLocation, Location, Message, PhysicalLocation, Region, Result as SarifResult,
        ResultLevel, Run, Sarif, Tool, ToolComponent,
    };

    let results: Vec<SarifResult> = issues
        .iter()
        .map(|issue| {
            let level = match issue.severity {
                IssueSeverity::Critical => ResultLevel::Error,
                IssueSeverity::Medium => ResultLevel::Warning,
                IssueSeverity::Low => ResultLevel::Note,
            };

            let uri = issue
                .fix_target
                .as_deref()
                .unwrap_or("session.jsonl")
                .to_string();
            let line = i64::try_from(issue.line).unwrap_or(i64::MAX);

            let location = Location::builder()
                .physical_location(
                    PhysicalLocation::builder()
                        .artifact_location(ArtifactLocation::builder().uri(uri).build())
                        .region(Region::builder().start_line(line).build())
                        .build(),
                )
                .build();

            SarifResult::builder()
                .message(Message::builder().text(issue.summary.clone()).build())
                .rule_id(issue.code.to_string())
                .level(level)
                .locations(vec![location])
                .properties(render_property_bag(&SarifProperties {
                    category: issue.category,
                    confidence: issue.confidence,
                    fix_safety: issue.fix_safety,
                    issue_id: &issue.id,
                }))
                .build()
        })
        .collect();

    let driver = ToolComponent::builder()
        .name("harness-observe".to_string())
        .version(env!("CARGO_PKG_VERSION").to_string())
        .information_uri("https://github.com/smykla-skalski/harness".to_string())
        .build();

    let run = Run::builder()
        .tool(Tool::builder().driver(driver).build())
        .results(results)
        .build();

    let sarif = Sarif::builder()
        .schema("https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json".to_string())
        .version(serde_json::Value::String("2.1.0".to_string()))
        .runs(vec![run])
        .build();

    render_json_pretty_string(&sarif)
}

fn render_property_bag<T>(properties: &T) -> PropertyBag
where
    T: Serialize,
{
    use serde_json::Value;

    let Value::Object(map) = serde_json::to_value(properties).expect("valid SARIF properties")
    else {
        unreachable!("serialized SARIF properties must be an object");
    };
    let additional_properties: BTreeMap<_, _> = map.into_iter().collect();
    PropertyBag::builder()
        .additional_properties(additional_properties)
        .build()
}

#[cfg(test)]
mod tests {
    use serde::Deserialize;

    use super::*;
    use crate::observe::types::{IssueCode, SourceTool};

    #[derive(Deserialize)]
    struct ParsedIssue {
        issue_id: String,
        line: usize,
        code: String,
        category: String,
        severity: String,
        confidence: String,
        fix_safety: String,
        summary: String,
        details: String,
        fingerprint: String,
        source_role: String,
        source_tool: Option<String>,
        fixable: bool,
        fix_target: Option<String>,
        fix_hint: Option<String>,
        evidence_excerpt: Option<String>,
    }

    #[derive(Deserialize)]
    struct ParsedSummary {
        status: String,
        last_line: usize,
        total_issues: usize,
        by_severity: BTreeMap<String, usize>,
        by_category: BTreeMap<String, usize>,
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
        assert_eq!(parsed.details.len(), DETAIL_TRUNCATE_LENGTH);
    }

    #[test]
    fn json_output_valid() {
        let parsed = parse_issue_json(&sample_issue());
        assert_eq!(parsed.line, 42);
        assert_eq!(parsed.category, "build_error");
        assert_eq!(parsed.severity, "critical");
        assert_eq!(parsed.issue_id, "abc123def456");
        assert_eq!(parsed.code, "build_or_lint_failure");
        assert_eq!(parsed.confidence, "high");
        assert_eq!(parsed.fix_safety, "auto_fix_safe");
        assert_eq!(parsed.summary, "Build failed");
        assert_eq!(parsed.fingerprint, "build_or_lint_failure");
        assert_eq!(parsed.source_role, "assistant");
        assert_eq!(parsed.fix_target.as_deref(), Some("src/main.rs"));
        assert_eq!(parsed.fix_hint.as_deref(), Some("Fix the type mismatch"));
        assert!(parsed.evidence_excerpt.is_none());
        assert!(parsed.fixable);
    }

    #[test]
    fn json_output_fixable_backward_compat() {
        let mut issue = sample_issue();
        issue.fix_safety = FixSafety::TriageRequired;
        assert!(!parse_issue_json(&issue).fixable);

        issue.fix_safety = FixSafety::AutoFixGuarded;
        assert!(parse_issue_json(&issue).fixable);
    }

    #[test]
    fn json_output_source_tool() {
        let mut issue = sample_issue();
        issue.source_tool = Some(SourceTool::Bash);
        assert_eq!(parse_issue_json(&issue).source_tool.as_deref(), Some("Bash"));
    }

    #[test]
    fn json_output_no_source_tool() {
        assert!(parse_issue_json(&sample_issue()).source_tool.is_none());
    }

    #[test]
    fn summary_counts() {
        let parsed = parse_summary_json(&[sample_issue(), sample_issue()], 100);
        assert_eq!(parsed.status, "done");
        assert_eq!(parsed.total_issues, 2);
        assert_eq!(parsed.last_line, 100);
        assert_eq!(parsed.by_severity.get("critical"), Some(&2));
        assert_eq!(parsed.by_category.get("build_error"), Some(&2));
    }

    #[test]
    fn summary_empty_issues() {
        let parsed = parse_summary_json(&[], 0);
        assert_eq!(parsed.total_issues, 0);
        assert!(parsed.by_category.is_empty());
        assert!(parsed.by_severity.is_empty());
    }
}
