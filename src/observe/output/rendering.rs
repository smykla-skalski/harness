use std::borrow::Cow;
use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap};

use serde::Serialize;
use serde_sarif::sarif::PropertyBag;

use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, SourceTool,
};

pub(super) const DETAIL_TRUNCATE_LENGTH: usize = 500;

#[derive(Serialize)]
pub(super) struct RenderedIssue<'a> {
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
pub(super) struct RenderedIssueSource {
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
pub(super) struct RenderedIssueRemediation<'a> {
    safety: FixSafety,
    available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<&'a str>,
}

#[derive(Serialize)]
pub(super) struct RenderedSummary {
    status: &'static str,
    cursor: RenderedSummaryCursor,
    issues: RenderedIssueSummary,
}

impl RenderedSummary {
    pub(super) fn new(issues: &[Issue], last_line: usize) -> Self {
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
pub(super) struct RenderedTopCauses<'a> {
    causes: Vec<RenderedTopCause<'a>>,
}

impl<'a> RenderedTopCauses<'a> {
    pub(super) fn new(issues: &'a [Issue], top_n: usize) -> Self {
        let mut counts: HashMap<IssueCode, RenderedTopCause<'a>> = HashMap::new();
        for issue in issues {
            let entry = counts
                .entry(issue.code)
                .or_insert_with(|| RenderedTopCause {
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
pub(super) struct RenderedMarkdownRow<'a> {
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
pub(super) struct SarifProperties<'a> {
    harness_observe: SarifObserveProperties<'a>,
}

impl<'a> SarifProperties<'a> {
    pub(super) fn from_issue(issue: &'a Issue) -> Self {
        Self {
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
        }
    }
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

pub(super) fn render_json_string<T>(value: &T) -> String
where
    T: Serialize,
{
    serde_json::to_string(value).expect("valid JSON serialization")
}

pub(super) fn render_json_pretty_string<T>(value: &T) -> String
where
    T: Serialize,
{
    serde_json::to_string_pretty(value).expect("valid JSON serialization")
}

pub(super) fn render_property_bag<T>(properties: &T) -> PropertyBag
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
