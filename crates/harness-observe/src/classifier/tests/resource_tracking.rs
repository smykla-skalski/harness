use super::*;

// ─── Resource cleanup tracking tests ───────────────────────────────

#[test]
fn resource_cleanup_tracks_apply_commands() {
    let mut state = make_state();
    let block = bash_tool_use("harness apply --manifest g13/01-meshtrace.yaml");
    check_tool_use_for_issues(10, &block, &mut state);
    assert!(state.pending_resource_creates.contains("01-meshtrace"));
}

#[test]
fn resource_cleanup_tracks_multiple_manifests() {
    let mut state = make_state();
    let block = bash_tool_use(
        "harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-containerpatch.yaml",
    );
    check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(state.pending_resource_creates.len(), 2);
    assert!(state.pending_resource_creates.contains("01-meshtrace"));
    assert!(state.pending_resource_creates.contains("02-containerpatch"));
}

#[test]
fn resource_cleanup_delete_removes_from_tracking() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);
    assert_eq!(state.pending_resource_creates.len(), 1);

    let delete = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness delete --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(20, &delete, &mut state);
    assert!(state.pending_resource_creates.is_empty());
}

#[test]
fn resource_cleanup_flags_uncleaned_on_group_report() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-motb.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(20, &report, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Low)
    );
}

#[test]
fn resource_cleanup_no_issue_when_all_deleted() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let delete = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness delete --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(20, &delete, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(30, &report, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
    );
}

#[test]
fn resource_cleanup_resets_after_group_report() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    check_tool_use_for_issues(20, &report, &mut state);
    assert!(
        state.pending_resource_creates.is_empty(),
        "should be cleared after group report"
    );

    // Second group report without any new applies should not fire
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group g14 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(30, &report2, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
    );
}

#[test]
fn resource_cleanup_partial_delete_flags_remaining() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml --manifest g13/02-containerpatch.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    // Only delete one of the two
    let delete = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness delete --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(20, &delete, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(30, &report, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
    );
    let cleanup_issue = issues
        .iter()
        .find(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
        .unwrap();
    assert!(cleanup_issue.details.contains("02-containerpatch"));
}

#[test]
fn resource_cleanup_output_shape() {
    let mut state = make_state();
    let apply = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply, &mut state);

    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues = check_tool_use_for_issues(20, &report, &mut state);
    assert_eq!(
        issues
            .iter()
            .filter(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
            .count(),
        1
    );
    let issue = issues
        .iter()
        .find(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
        .unwrap();
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("Delete test resources"))
    );
    assert_eq!(issue.source_tool, Some(SourceTool::Bash));
}

#[test]
fn resource_cleanup_ignores_non_harness_commands() {
    let mut state = make_state();
    let block = bash_tool_use("kubectl apply -f manifest.yaml");
    check_tool_use_for_issues(10, &block, &mut state);
    assert!(state.pending_resource_creates.is_empty());
}

#[test]
fn resource_cleanup_deduplicates_across_groups() {
    let mut state = make_state();

    // First group with uncleaned resources
    let apply1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g13/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(10, &apply1, &mut state);

    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group g13 --verdict pass" }
    });
    let issues1 = check_tool_use_for_issues(20, &report1, &mut state);
    assert_eq!(
        issues1
            .iter()
            .filter(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd)
            .count(),
        1
    );

    // Second group with the same uncleaned resource name - deduplicates
    let apply2 = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness apply --manifest g14/01-meshtrace.yaml" }
    });
    check_tool_use_for_issues(30, &apply2, &mut state);

    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t4",
        "name": "Bash",
        "input": { "command": "harness report group --group g14 --verdict pass" }
    });
    let issues2 = check_tool_use_for_issues(40, &report2, &mut state);
    // Same fingerprint ("01-meshtrace") so it deduplicates
    assert!(
        !issues2
            .iter()
            .any(|i| i.code == IssueCode::ResourceNotCleanedUpBeforeGroupEnd),
        "same fingerprint should be deduplicated"
    );
}

// ─── Capture between groups tracking tests ────────────────────────

#[test]
fn first_group_report_does_not_flag_missing_capture() {
    let mut state = make_state();
    let report = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    let issues = check_tool_use_for_issues(10, &report, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture),
        "first group should not flag missing capture"
    );
    assert!(state.seen_any_group_report);
    assert!(!state.seen_capture_since_last_group_report);
}

#[test]
fn second_group_without_capture_flags_issue() {
    let mut state = make_state();

    // First group report
    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    check_tool_use_for_issues(10, &report1, &mut state);

    // Second group report without capture in between
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g02 --status pass --evidence-label e2" }
    });
    let issues = check_tool_use_for_issues(20, &report2, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture
                && i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Medium),
        "second group without capture should flag issue"
    );
}

#[test]
fn capture_between_groups_prevents_flag() {
    let mut state = make_state();

    // First group
    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    check_tool_use_for_issues(10, &report1, &mut state);

    // Capture between groups
    let capture = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness capture --label after-g01" }
    });
    check_tool_use_for_issues(15, &capture, &mut state);

    // Second group
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t3",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g02 --status pass --evidence-label e2" }
    });
    let issues = check_tool_use_for_issues(20, &report2, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture),
        "capture between groups should prevent flag"
    );
}

#[test]
fn capture_label_on_report_prevents_flag() {
    let mut state = make_state();

    // First group
    let report1 = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g01 --status pass --evidence-label e1" }
    });
    check_tool_use_for_issues(10, &report1, &mut state);

    // Second group with --capture-label (inline capture)
    let report2 = serde_json::json!({
        "type": "tool_use",
        "id": "t2",
        "name": "Bash",
        "input": { "command": "harness report group --group-id g02 --status pass --capture-label after-g02" }
    });
    let issues = check_tool_use_for_issues(20, &report2, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.code == IssueCode::GroupReportedWithoutCapture),
        "--capture-label should prevent flag"
    );
}
