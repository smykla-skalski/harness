//! Integration coverage for the observer issue-aware severity bridge
//! (`session::observe::task_severity_for_issue`). The pinned heuristics
//! must route high-impact codes to `TaskSeverity::High` or
//! `TaskSeverity::Critical` regardless of the classifier's
//! `IssueSeverity` tier.

use harness::observe::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole,
};
use harness::session::observe::task_severity_for_issue;
use harness::session::types::TaskSeverity;

fn issue_with(code: IssueCode, severity: IssueSeverity) -> Issue {
    Issue {
        id: format!("{code}/fixture/1"),
        line: 1,
        code,
        category: IssueCategory::UnexpectedBehavior,
        severity,
        confidence: Confidence::Medium,
        fix_safety: FixSafety::TriageRequired,
        summary: format!("synthetic {code}"),
        details: String::new(),
        fingerprint: code.to_string(),
        source_role: MessageRole::Assistant,
        source_tool: None,
        fix_target: None,
        fix_hint: None,
        evidence_excerpt: None,
    }
}

#[test]
fn python_traceback_output_routes_to_high_severity_even_on_medium_issue() {
    let issue = issue_with(IssueCode::PythonTracebackOutput, IssueSeverity::Medium);
    assert_eq!(task_severity_for_issue(&issue), TaskSeverity::High);
}

#[test]
fn hook_denied_tool_call_routes_to_high_severity_even_on_low_issue() {
    let issue = issue_with(IssueCode::HookDeniedToolCall, IssueSeverity::Low);
    assert_eq!(task_severity_for_issue(&issue), TaskSeverity::High);
}

#[test]
fn python_used_in_bash_tool_use_routes_to_high_severity() {
    let issue = issue_with(IssueCode::PythonUsedInBashToolUse, IssueSeverity::Low);
    assert_eq!(task_severity_for_issue(&issue), TaskSeverity::High);
}

#[test]
fn cross_agent_file_conflict_routes_to_high_severity() {
    let issue = issue_with(IssueCode::CrossAgentFileConflict, IssueSeverity::Medium);
    assert_eq!(task_severity_for_issue(&issue), TaskSeverity::High);
}

#[test]
fn unauthorized_git_commit_routes_to_critical() {
    let issue = issue_with(
        IssueCode::UnauthorizedGitCommitDuringRun,
        IssueSeverity::Medium,
    );
    assert_eq!(task_severity_for_issue(&issue), TaskSeverity::Critical);
}

#[test]
fn unverified_recursive_remove_routes_to_critical_even_on_low_issue() {
    let issue = issue_with(IssueCode::UnverifiedRecursiveRemove, IssueSeverity::Low);
    assert_eq!(task_severity_for_issue(&issue), TaskSeverity::Critical);
}

#[test]
fn non_overridden_issue_uses_base_severity_mapping() {
    let issue_low = issue_with(IssueCode::JqErrorInCommandOutput, IssueSeverity::Low);
    assert_eq!(task_severity_for_issue(&issue_low), TaskSeverity::Low);
    let issue_medium = issue_with(IssueCode::JqErrorInCommandOutput, IssueSeverity::Medium);
    assert_eq!(task_severity_for_issue(&issue_medium), TaskSeverity::Medium);
    let issue_critical = issue_with(IssueCode::JqErrorInCommandOutput, IssueSeverity::Critical);
    assert_eq!(
        task_severity_for_issue(&issue_critical),
        TaskSeverity::Critical
    );
}
