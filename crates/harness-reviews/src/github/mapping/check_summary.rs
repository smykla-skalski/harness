use std::collections::BTreeSet;

use super::super::check_status::{is_failed_check_conclusion, normalized_details_url};
use super::super::types::{CommitConnection, RefNode, StatusContextNode};
use super::super::{ReviewCheck, ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus};
use super::enums::{map_check_conclusion, map_check_run_status, map_status_context_conclusion};

#[derive(Default)]
pub(super) struct CheckSummary {
    pub(super) checks: Vec<ReviewCheck>,
    pending: u64,
    failed: u64,
    total: u64,
    pub(super) policy_blocked: bool,
    pub(super) next_page_cursor: Option<String>,
}

impl CheckSummary {
    pub(super) fn from_commits(commits: CommitConnection) -> Self {
        let mut summary = Self::default();
        let Some(rollup) = commits
            .nodes
            .into_iter()
            .last()
            .and_then(|node| node.commit)
            .and_then(|commit| commit.status_check_rollup)
        else {
            return summary;
        };
        if rollup.contexts.page_info.has_next_page {
            summary
                .next_page_cursor
                .clone_from(&rollup.contexts.page_info.end_cursor);
        }
        for context in rollup.contexts.nodes {
            summary.push_context(context);
        }
        summary
    }

    pub(super) fn push_context(&mut self, context: StatusContextNode) {
        match context {
            StatusContextNode::CheckRun {
                name,
                status,
                conclusion,
                url,
                check_suite,
            } => self.push_check_run(
                name,
                status.as_deref(),
                conclusion.as_deref(),
                check_suite.and_then(|suite| suite.id),
                url,
            ),
            StatusContextNode::StatusContext {
                context,
                state,
                target_url,
            } => {
                self.push_status_context(context, state.as_deref(), target_url);
            }
        }
    }

    fn push_check_run(
        &mut self,
        name: String,
        status: Option<&str>,
        conclusion: Option<&str>,
        check_suite_id: Option<String>,
        details_url: Option<String>,
    ) {
        self.total += 1;
        let status = map_check_run_status(status);
        let conclusion = map_check_conclusion(conclusion);
        if status != ReviewCheckRunStatus::Completed {
            self.pending += 1;
        } else if is_failed_check_conclusion(conclusion) {
            self.failed += 1;
        }
        self.checks.push(ReviewCheck {
            name,
            status,
            conclusion,
            check_suite_id,
            details_url: normalized_details_url(details_url),
        });
    }

    fn push_status_context(
        &mut self,
        context: String,
        state: Option<&str>,
        details_url: Option<String>,
    ) {
        if context == "renovate/stability-days" && !matches!(state, Some("SUCCESS")) {
            self.policy_blocked = true;
            return;
        }
        self.total += 1;
        let conclusion = map_status_context_conclusion(state);
        if matches!(conclusion, ReviewCheckConclusion::Failure) {
            self.failed += 1;
        }
        self.checks.push(ReviewCheck {
            name: context,
            status: ReviewCheckRunStatus::Completed,
            conclusion,
            check_suite_id: None,
            details_url: normalized_details_url(details_url),
        });
    }

    pub(super) fn status(&self) -> ReviewCheckStatus {
        if self.total == 0 {
            ReviewCheckStatus::None
        } else if self.failed > 0 {
            ReviewCheckStatus::Failure
        } else if self.pending > 0 {
            ReviewCheckStatus::Pending
        } else {
            ReviewCheckStatus::Success
        }
    }
}

pub(super) fn required_check_names(base_ref: Option<&RefNode>) -> Vec<String> {
    let Some(branch_protection) =
        base_ref.and_then(|base_ref| base_ref.branch_protection_rule.as_ref())
    else {
        return Vec::new();
    };
    let mut names = BTreeSet::new();
    for context in &branch_protection.required_status_check_contexts {
        names.insert(context.clone());
    }
    for check in &branch_protection.required_status_checks {
        names.insert(check.context.clone());
    }
    names.into_iter().collect()
}

pub(super) fn required_failed_check_names(
    checks: &[ReviewCheck],
    required_check_names: &[String],
) -> Vec<String> {
    let required = required_check_names
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    checks
        .iter()
        .filter(|check| {
            required.contains(check.name.as_str()) && is_failed_check_conclusion(check.conclusion)
        })
        .map(|check| check.name.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

pub(super) fn recompute_check_status(checks: &[ReviewCheck]) -> ReviewCheckStatus {
    if checks.is_empty() {
        return ReviewCheckStatus::None;
    }
    let mut pending = 0_u64;
    let mut failed = 0_u64;
    for check in checks {
        if check.status != ReviewCheckRunStatus::Completed {
            pending += 1;
        } else if is_failed_check_conclusion(check.conclusion) {
            failed += 1;
        }
    }
    if failed > 0 {
        ReviewCheckStatus::Failure
    } else if pending > 0 {
        ReviewCheckStatus::Pending
    } else {
        ReviewCheckStatus::Success
    }
}
