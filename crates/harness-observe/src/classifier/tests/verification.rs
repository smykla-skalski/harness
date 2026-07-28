use super::*;

// ─── Truncated verification output tests ───────────────────────────

#[test]
fn detects_make_test_piped_through_tail() {
    let mut state = make_state();
    let block = bash_tool_use("make test | tail -10");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Low)
    );
}

#[test]
fn detects_cargo_clippy_piped_through_head() {
    let mut state = make_state();
    let block = bash_tool_use("cargo clippy --lib 2>&1 | head -20");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn detects_cargo_test_piped_through_tail() {
    let mut state = make_state();
    let block = bash_tool_use("cargo test --lib 2>&1 | tail -15");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn detects_make_check_piped_through_tail() {
    let mut state = make_state();
    let block = bash_tool_use("make check 2>&1 | tail -5");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn detects_lint_command_piped_through_head() {
    let mut state = make_state();
    let block = bash_tool_use("golangci-lint run ./... | head -20");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated),
        "lint command piped through head should fire"
    );
}

#[test]
fn skips_tail_without_verification_keyword() {
    let mut state = make_state();
    let block = bash_tool_use("ls -la /tmp | tail -5");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated),
        "non-verification commands should not trigger"
    );
}

#[test]
fn skips_head_without_verification_keyword() {
    let mut state = make_state();
    let block = bash_tool_use("cat output.log | head -50");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated)
    );
}

#[test]
fn skips_verification_keyword_without_pipe() {
    let mut state = make_state();
    let block = bash_tool_use("make test");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::VerificationOutputTruncated),
        "no pipe means no truncation"
    );
}

#[test]
fn truncated_verification_output_shape() {
    let mut state = make_state();
    let block = bash_tool_use("make test 2>&1 | tail -10");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    let issue = issues
        .iter()
        .find(|i| i.code == IssueCode::VerificationOutputTruncated)
        .expect("should detect truncated verification output");
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("grep"))
    );
    assert_eq!(issue.source_tool, Some(SourceTool::Bash));
}
