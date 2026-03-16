use crate::commands::observe::truncate_details;
use crate::commands::observe::types::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole,
    OccurrenceTracker, ScanState, SourceTool, compute_issue_id,
};

/// Internal guidance shape for classifier authors.
#[derive(Debug, Clone)]
pub(super) enum Guidance {
    None,
    Advisory {
        target: Option<String>,
        hint: String,
    },
    Fix {
        target: Option<String>,
        hint: Option<String>,
    },
}

impl Guidance {
    pub(super) fn advisory(hint: impl Into<String>) -> Self {
        Self::Advisory {
            target: None,
            hint: hint.into(),
        }
    }

    pub(super) fn advisory_target(target: impl Into<String>, hint: impl Into<String>) -> Self {
        Self::Advisory {
            target: Some(target.into()),
            hint: hint.into(),
        }
    }

    pub(super) fn fix() -> Self {
        Self::Fix {
            target: None,
            hint: None,
        }
    }

    pub(super) fn fix_hint(hint: impl Into<String>) -> Self {
        Self::Fix {
            target: None,
            hint: Some(hint.into()),
        }
    }

    pub(super) fn fix_target(target: impl Into<String>) -> Self {
        Self::Fix {
            target: Some(target.into()),
            hint: None,
        }
    }

    pub(super) fn fix_target_hint(target: impl Into<String>, hint: impl Into<String>) -> Self {
        Self::Fix {
            target: Some(target.into()),
            hint: Some(hint.into()),
        }
    }

    fn materialize(self) -> (FixSafety, Option<String>, Option<String>) {
        match self {
            Self::None => (FixSafety::AdvisoryOnly, None, None),
            Self::Advisory { target, hint } => (FixSafety::AdvisoryOnly, target, Some(hint)),
            Self::Fix { target, hint } => (FixSafety::AutoFixSafe, target, hint),
        }
    }
}

/// Internal typed issue definition before details are truncated and serialized.
#[derive(Debug, Clone)]
pub(super) struct IssueBlueprint {
    code: IssueCode,
    category: IssueCategory,
    severity: IssueSeverity,
    summary: String,
    fingerprint: String,
    guidance: Guidance,
    confidence: Confidence,
    fix_safety: Option<FixSafety>,
    source_tool: Option<SourceTool>,
}

impl IssueBlueprint {
    pub(super) fn new(
        code: IssueCode,
        category: IssueCategory,
        severity: IssueSeverity,
        summary: impl Into<String>,
    ) -> Self {
        let summary = summary.into();
        Self {
            code,
            category,
            severity,
            fingerprint: summary.clone(),
            summary,
            guidance: Guidance::None,
            confidence: Confidence::High,
            fix_safety: None,
            source_tool: None,
        }
    }

    pub(super) fn with_fingerprint(mut self, fingerprint: impl Into<String>) -> Self {
        self.fingerprint = fingerprint.into();
        self
    }

    pub(super) fn with_guidance(mut self, guidance: Guidance) -> Self {
        self.guidance = guidance;
        self
    }

    pub(super) fn with_confidence(mut self, confidence: Confidence) -> Self {
        self.confidence = confidence;
        self
    }

    pub(super) fn with_fix_safety(mut self, fix_safety: FixSafety) -> Self {
        self.fix_safety = Some(fix_safety);
        self
    }

    pub(super) fn with_source_tool(mut self, source_tool: Option<SourceTool>) -> Self {
        self.source_tool = source_tool;
        self
    }
}

/// Shared emission path for all classifier producers.
pub(super) struct IssueEmitter<'a> {
    line: usize,
    role: MessageRole,
    state: &'a mut ScanState,
}

impl<'a> IssueEmitter<'a> {
    pub(super) fn new(line: usize, role: MessageRole, state: &'a mut ScanState) -> Self {
        Self { line, role, state }
    }

    pub(super) fn emit(
        &mut self,
        issues: &mut Vec<Issue>,
        blueprint: IssueBlueprint,
        details: &str,
    ) -> bool {
        let dedup_key = (blueprint.code, blueprint.fingerprint.clone());

        // Track occurrences even for duplicates
        let tracker = self
            .state
            .issue_occurrences
            .entry(dedup_key.clone())
            .or_insert_with(|| OccurrenceTracker {
                count: 0,
                first_seen_line: self.line,
                last_seen_line: self.line,
            });
        tracker.count += 1;
        tracker.last_seen_line = self.line;

        if !self.state.seen_issues.insert(dedup_key) {
            return false;
        }

        let (guidance_fix_safety, fix_target, fix_hint) = blueprint.guidance.materialize();
        let fix_safety = blueprint.fix_safety.unwrap_or(guidance_fix_safety);
        let issue_id = compute_issue_id(&blueprint.code, &blueprint.fingerprint);

        issues.push(Issue {
            issue_id,
            line: self.line,
            code: blueprint.code,
            category: blueprint.category,
            severity: blueprint.severity,
            confidence: blueprint.confidence,
            fix_safety,
            summary: blueprint.summary,
            details: truncate_details(details),
            fingerprint: blueprint.fingerprint,
            source_role: self.role,
            source_tool: blueprint.source_tool,
            fix_target,
            fix_hint,
            evidence_excerpt: None,
        });
        true
    }
}
