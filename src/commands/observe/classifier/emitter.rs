use crate::commands::observe::truncate_details;
use crate::commands::observe::types::{
    Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole, ScanState,
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

    fn materialize(self) -> (bool, Option<String>, Option<String>) {
        match self {
            Self::None => (false, None, None),
            Self::Advisory { target, hint } => (false, target, Some(hint)),
            Self::Fix { target, hint } => (true, target, hint),
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
        if !self
            .state
            .seen_issues
            .insert((blueprint.code, blueprint.fingerprint.clone()))
        {
            return false;
        }

        let (fixable, fix_target, fix_hint) = blueprint.guidance.materialize();
        issues.push(Issue {
            line: self.line,
            category: blueprint.category,
            severity: blueprint.severity,
            summary: blueprint.summary,
            details: truncate_details(details),
            source_role: self.role,
            fixable,
            fix_target,
            fix_hint,
        });
        true
    }
}
