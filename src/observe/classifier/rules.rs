use std::collections::HashSet;

use super::emitter::{Guidance, IssueBlueprint, IssueEmitter};
use super::registry::issue_code_meta;
use crate::observe::types::{Issue, IssueCategory, IssueCode, MessageRole, ScanState, SourceTool};

#[path = "rules/data.rs"]
mod data;

pub(crate) use self::data::TEXT_RULES;

/// Filter on message role.
#[derive(Clone, Copy)]
pub(super) enum RoleFilter {
    /// No filter - any role matches.
    Any,
    /// Must match this exact role.
    Exact(MessageRole),
}

/// Filter on source tool.
#[derive(Clone, Copy)]
pub(super) enum ToolFilter {
    /// No filter - any source tool (including None).
    Any,
    /// Must match this exact source tool.
    Exact(SourceTool),
    /// Source tool must be None (plain text, not tool output).
    Absent,
}

/// How to match patterns against lowercased text.
#[derive(Clone, Copy)]
pub(super) enum MatchMode {
    /// Stop at the first matching pattern; include it in summary if requested.
    FirstMatch,
    /// Check if any pattern matches (no specific pattern in summary).
    Any,
}

/// Additional text guard applied before pattern matching.
#[derive(Clone, Copy)]
pub(super) enum Guard {
    None,
    Contains(&'static str),
}

impl Guard {
    fn matches(self, lower: &str) -> bool {
        match self {
            Self::None => true,
            Self::Contains(needle) => lower.contains(needle),
        }
    }
}

/// How the rule summary is rendered for a hit.
#[derive(Clone, Copy)]
pub(super) enum SummaryTemplate {
    Static(&'static str),
    PrefixWithPattern(&'static str),
}

impl SummaryTemplate {
    fn render(self, matched_pattern: &str) -> String {
        match self {
            Self::Static(summary) => summary.to_string(),
            Self::PrefixWithPattern(prefix) => format!("{prefix}{matched_pattern}"),
        }
    }
}

/// How the dedup fingerprint should be derived for a rule hit.
#[derive(Clone, Copy)]
pub(super) enum FingerprintMode {
    /// One semantic issue for the whole rule.
    Static,
    /// Different matched patterns should be emitted independently.
    MatchedPattern,
}

/// Internal guidance for static rules.
#[derive(Clone, Copy)]
pub(super) enum RuleGuidance {
    None,
    Advisory {
        target: Option<&'static str>,
        hint: &'static str,
    },
    Fix {
        target: Option<&'static str>,
        hint: Option<&'static str>,
    },
}

impl RuleGuidance {
    fn into_guidance(self) -> Guidance {
        match self {
            Self::None => Guidance::None,
            Self::Advisory { target, hint } => {
                if let Some(target) = target {
                    Guidance::advisory_target(target, hint)
                } else {
                    Guidance::advisory(hint)
                }
            }
            Self::Fix { target, hint } => match (target, hint) {
                (Some(target), Some(hint)) => Guidance::fix_target_hint(target, hint),
                (Some(target), None) => Guidance::fix_target(target),
                (None, Some(hint)) => Guidance::fix_hint(hint),
                (None, None) => Guidance::fix(),
            },
        }
    }
}

/// A declarative text classification rule. Rules are evaluated in order;
/// each matched rule adds its category to the matched set so later rules
/// can skip via `skip_if_matched`.
pub(super) struct TextRule {
    pub code: IssueCode,
    pub role_filter: RoleFilter,
    pub source_tool_filter: ToolFilter,
    pub guard: Guard,
    pub patterns: &'static [&'static str],
    pub match_mode: MatchMode,
    pub fingerprint_mode: FingerprintMode,
    pub summary: SummaryTemplate,
    pub guidance: RuleGuidance,
    pub skip_if_matched: &'static [IssueCategory],
}

/// Check whether a rule's filters (role, source tool, guard) all pass.
fn rule_matches_filters(
    text_rule: &TextRule,
    role: MessageRole,
    source_tool: Option<SourceTool>,
    lower: &str,
) -> bool {
    match text_rule.role_filter {
        RoleFilter::Exact(r) if role != r => return false,
        _ => {}
    }
    match text_rule.source_tool_filter {
        ToolFilter::Exact(t) if source_tool != Some(t) => return false,
        ToolFilter::Absent if source_tool.is_some() => return false,
        _ => {}
    }
    text_rule.guard.matches(lower)
}

/// Find the first matching pattern for a rule against lowercased text.
fn find_matched_pattern<'a>(rule: &'a TextRule, lower: &str) -> Option<&'a str> {
    match rule.match_mode {
        MatchMode::FirstMatch | MatchMode::Any => {
            rule.patterns.iter().find(|p| lower.contains(*p)).copied()
        }
    }
}

/// Derive the dedup fingerprint for a rule hit.
fn build_fingerprint(rule: &TextRule, pattern: &str) -> String {
    match rule.fingerprint_mode {
        FingerprintMode::Static => match rule.summary {
            SummaryTemplate::Static(summary) => summary.to_string(),
            SummaryTemplate::PrefixWithPattern(prefix) => prefix.to_string(),
        },
        FingerprintMode::MatchedPattern => pattern.to_string(),
    }
}

/// Apply the static rule table against a text block. Returns the issues found
/// and the set of matched categories (for downstream skip logic).
pub(super) fn apply_text_rules(
    line_num: usize,
    role: MessageRole,
    text: &str,
    lower: &str,
    source_tool: Option<SourceTool>,
    state: &mut ScanState,
) -> (Vec<Issue>, HashSet<IssueCategory>) {
    let mut issues = Vec::new();
    let mut matched_categories = HashSet::new();
    let mut emitter = IssueEmitter::new(line_num, role, state);

    for rule in TEXT_RULES {
        if rule
            .skip_if_matched
            .iter()
            .any(|cat| matched_categories.contains(cat))
        {
            continue;
        }
        if !rule_matches_filters(rule, role, source_tool, lower) {
            continue;
        }
        if let Some(pattern) = find_matched_pattern(rule, lower) {
            let fingerprint = build_fingerprint(rule, pattern);
            let meta =
                issue_code_meta(rule.code).expect("issue code registry should cover every code");
            let blueprint = IssueBlueprint::from_code(rule.code, rule.summary.render(pattern))
                .with_fingerprint(fingerprint)
                .with_guidance(rule.guidance.into_guidance())
                .with_source_tool(source_tool);
            emitter.emit(&mut issues, blueprint, text);
            matched_categories.insert(meta.default_category);
        }
    }

    (issues, matched_categories)
}
