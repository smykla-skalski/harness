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
    id: &'a str,
    location: RenderedIssueLocation,
    classification: RenderedIssueClassification<'a>,
    source: RenderedIssueSource,
    message: RenderedIssueMessage<'a>,
    remediation: RenderedIssueRemediation<'a>,
}

impl<'a> From<&'a Issue> for RenderedIssue<'a> {
    fn from(issue: &'a Issue) -> Self {
        Self {
            id: &issue.id,
            location: RenderedIssueLocation { line: issue.line },
            classification: RenderedIssueClassification {
                code: issue.code,
                category: issue.category,
                severity: issue.severity,
                confidence: issue.confidence,
                fingerprint: &issue.fingerprint,
            },
            source: RenderedIssueSource {
                role: issue.source_role,
                tool: issue.source_tool,
            },
            message: RenderedIssueMessage {
                summary: &issue.summary,
                details: truncate_details(&issue.details),
                evidence_excerpt: issue.evidence_excerpt.as_deref(),
            },
            remediation: RenderedIssueRemediation {
                safety: issue.fix_safety,
                available: issue.fix_safety.is_fixable(),
                target: issue.fix_target.as_deref(),
                hint: issue.fix_hint.as_deref(),
            },
        }
    }
}

#[derive(Serialize)]
struct RenderedIssueLocation {
    line: usize,
}

#[derive(Serialize)]
struct RenderedIssueClassification<'a> {
    code: IssueCode,
    category: IssueCategory,
    severity: IssueSeverity,
    confidence: Confidence,
    fingerprint: &'a str,
}

#[derive(Serialize)]
struct RenderedIssueSource {
    role: MessageRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool: Option<SourceTool>,
}

#[derive(Serialize)]
struct RenderedIssueMessage<'a> {
    summary: &'a str,
    details: Cow<'a, str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    evidence_excerpt: Option<&'a str>,
}

#[derive(Serialize)]
struct RenderedIssueRemediation<'a> {
    safety: FixSafety,
    available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<&'a str>,
}

#[derive(Serialize)]
struct RenderedSummary {
    status: &'static str,
    cursor: RenderedSummaryCursor,
    issues: RenderedIssueSummary,
}

impl RenderedSummary {
    fn new(issues: &[Issue], last_line: usize) -> Self {
        Self {
            status: "done",
            cursor: RenderedSummaryCursor { last_line },
            issues: RenderedIssueSummary::new(issues),
        }
    }
}

#[derive(Serialize)]
struct RenderedSummaryCursor {
    last_line: usize,
}

#[derive(Serialize)]
struct RenderedIssueSummary {
    total: usize,
    by_severity: Vec<RenderedSeverityCount>,
    by_category: Vec<RenderedCategoryCount>,
}

impl RenderedIssueSummary {
    fn new(issues: &[Issue]) -> Self {
        let mut severity_counts: HashMap<IssueSeverity, usize> = HashMap::new();
        let mut category_counts: HashMap<IssueCategory, usize> = HashMap::new();

        for issue in issues {
            *severity_counts.entry(issue.severity).or_insert(0) += 1;
            *category_counts.entry(issue.category).or_insert(0) += 1;
        }

        let by_severity = [
            IssueSeverity::Critical,
            IssueSeverity::Medium,
            IssueSeverity::Low,
        ]
        .into_iter()
        .filter_map(|severity| {
            severity_counts
                .get(&severity)
                .copied()
                .map(|count| RenderedSeverityCount { severity, count })
        })
        .collect();

        let by_category = IssueCategory::ALL
            .iter()
            .copied()
            .filter_map(|category| {
                category_counts
                    .get(&category)
                    .copied()
                    .map(|count| RenderedCategoryCount { category, count })
            })
            .collect();

        Self {
            total: issues.len(),
            by_severity,
            by_category,
        }
    }
}

#[derive(Serialize)]
struct RenderedSeverityCount {
    severity: IssueSeverity,
    count: usize,
}

#[derive(Serialize)]
struct RenderedCategoryCount {
    category: IssueCategory,
    count: usize,
}

#[derive(Serialize)]
struct RenderedTopCauses<'a> {
    causes: Vec<RenderedTopCause<'a>>,
}

impl<'a> RenderedTopCauses<'a> {
    fn new(issues: &'a [Issue], top_n: usize) -> Self {
        let mut counts: HashMap<IssueCode, RenderedTopCause<'a>> = HashMap::new();
        for issue in issues {
            let entry = counts.entry(issue.code).or_insert_with(|| RenderedTopCause {
                code: issue.code,
                occurrences: 0,
                summary: &issue.summary,
            });
            entry.occurrences += 1;
        }

        let mut causes: Vec<_> = counts.into_values().collect();
        causes.sort_by(|left, right| {
            Reverse(left.occurrences)
                .cmp(&Reverse(right.occurrences))
                .then_with(|| left.code.to_string().cmp(&right.code.to_string()))
        });
        causes.truncate(top_n);
        Self { causes }
    }
}

#[derive(Serialize)]
struct RenderedTopCause<'a> {
    code: IssueCode,
    occurrences: usize,
    summary: &'a str,
}

#[derive(Serialize, tabled::Tabled)]
struct RenderedMarkdownRow<'a> {
    line: usize,
    severity: IssueSeverity,
    category: IssueCategory,
    code: IssueCode,
    summary: &'a str,
}

impl<'a> From<&'a Issue> for RenderedMarkdownRow<'a> {
    fn from(issue: &'a Issue) -> Self {
        Self {
            line: issue.line,
            severity: issue.severity,
            category: issue.category,
            code: issue.code,
            summary: &issue.summary,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SarifProperties<'a> {
    harness_observe: SarifObserveProperties<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SarifObserveProperties<'a> {
    id: &'a str,
    classification: SarifIssueClassification<'a>,
    source: RenderedIssueSource,
    remediation: RenderedIssueRemediation<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SarifIssueClassification<'a> {
    code: IssueCode,
    category: IssueCategory,
    confidence: Confidence,
    fingerprint: &'a str,
}

fn truncate_details(details: &str) -> Cow<'_, str> {
    if details.len() <= DETAIL_TRUNCATE_LENGTH {
        Cow::Borrowed(details)
    } else {
        let boundary = details.floor_char_boundary(DETAIL_TRUNCATE_LENGTH);
        Cow::Owned(details[..boundary].to_string())
    }
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
                    harness_observe: SarifObserveProperties {
                        id: &issue.id,
                        classification: SarifIssueClassification {
                            code: issue.code,
                            category: issue.category,
                            confidence: issue.confidence,
                            fingerprint: &issue.fingerprint,
                        },
                        source: RenderedIssueSource {
                            role: issue.source_role,
                            tool: issue.source_tool,
                        },
                        remediation: RenderedIssueRemediation {
                            safety: issue.fix_safety,
                            available: issue.fix_safety.is_fixable(),
                            target: issue.fix_target.as_deref(),
                            hint: issue.fix_hint.as_deref(),
                        },
                    },
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
        assert_eq!(parsed.id, "abc123def456");
        assert_eq!(parsed.location.line, 42);
        assert_eq!(parsed.classification.code, "build_or_lint_failure");
        assert_eq!(parsed.classification.category, "build_error");
        assert_eq!(parsed.classification.severity, "critical");
        assert_eq!(parsed.classification.confidence, "high");
        assert_eq!(parsed.classification.fingerprint, "build_or_lint_failure");
        assert_eq!(parsed.source.role, "assistant");
        assert!(parsed.source.tool.is_none());
        assert_eq!(parsed.message.summary, "Build failed");
        assert_eq!(parsed.remediation.safety, "auto_fix_safe");
        assert!(parsed.remediation.available);
        assert_eq!(parsed.remediation.target.as_deref(), Some("src/main.rs"));
        assert_eq!(
            parsed.remediation.hint.as_deref(),
            Some("Fix the type mismatch")
        );
        assert!(parsed.message.evidence_excerpt.is_none());
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
        assert_eq!(parse_issue_json(&issue).source.tool.as_deref(), Some("Bash"));
    }

    #[test]
    fn summary_counts_use_typed_arrays() {
        let parsed = parse_summary_json(&[sample_issue(), sample_issue()], 100);
        assert_eq!(parsed.status, "done");
        assert_eq!(parsed.cursor.last_line, 100);
        assert_eq!(parsed.issues.total, 2);
        assert_eq!(parsed.issues.by_severity.len(), 1);
        assert_eq!(parsed.issues.by_severity[0].severity, "critical");
        assert_eq!(parsed.issues.by_severity[0].count, 2);
        assert_eq!(parsed.issues.by_category.len(), 1);
        assert_eq!(parsed.issues.by_category[0].category, "build_error");
        assert_eq!(parsed.issues.by_category[0].count, 2);
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
}
