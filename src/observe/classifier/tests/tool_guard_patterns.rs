use super::*;

#[test]
fn detects_absolute_manifest_path() {
    let mut state = make_state();
    let block = bash_tool_use(
        "harness apply --manifest /Users/someone/.local/share/harness/suites/motb/groups/g13/01.yaml",
    );
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Medium
                && i.summary.contains("Absolute path"))
    );
}

#[test]
fn detects_absolute_manifest_path_with_multiple_flags() {
    let mut state = make_state();
    let block = bash_tool_use(
        "harness apply --manifest /tmp/groups/g02/04.yaml --manifest /tmp/groups/g02/05.yaml",
    );
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(issues.iter().any(|i| i.summary.contains("Absolute path")));
}

#[test]
fn skips_relative_manifest_path() {
    let mut state = make_state();
    let block = bash_tool_use("harness apply --manifest g13/01.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("Absolute path")));
}

#[test]
fn skips_absolute_path_detection_for_non_apply_commands() {
    let mut state = make_state();
    let block = bash_tool_use("harness run --label test kubectl get pods");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("Absolute path")));
}

#[test]
fn absolute_manifest_path_output_shape() {
    let mut state = make_state();
    let block = bash_tool_use("harness apply --manifest /full/path/to/g13/01.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("relative manifest paths"))
    );
}

#[test]
fn detects_sleep_and_ampersand_harness() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 8 && harness apply --manifest g13/01.yaml");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Low
                && i.summary.contains("Sleep prefix"))
    );
}

#[test]
fn detects_sleep_and_semicolon_harness() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 5; harness record --label test -- kubectl get pods");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::UnexpectedBehavior
                && i.severity == IssueSeverity::Low
                && i.summary.contains("Sleep prefix"))
    );
}

#[test]
fn skips_sleep_without_harness_continuation() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 5 && echo done");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(!issues.iter().any(|i| i.summary.contains("Sleep prefix")));
}

#[test]
fn sleep_prefix_output_shape() {
    let mut state = make_state();
    let block = bash_tool_use("sleep 10 && harness capture --label post-apply");
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(issue.fix_safety.is_fixable());
    assert!(issue.fix_target.is_none());
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("--delay"))
    );
}

#[test]
fn detects_manifest_created_in_manifests_directory() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/home/user/.local/share/harness/runs/20260315/manifests/containerpatch-otel-env.yaml",
            "content": "apiVersion: kuma.io/v1alpha1\nkind: ContainerPatch"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::SkillBehavior
                && i.severity == IssueSeverity::Critical
                && i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn detects_manifest_yml_extension_in_manifests_directory() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Edit",
        "input": {
            "file_path": "/data/suites/motb/manifests/policy.yml",
            "old_string": "old",
            "new_string": "new"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        issues
            .iter()
            .any(|i| i.category == IssueCategory::SkillBehavior
                && i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn skips_manifest_detection_for_non_yaml_files() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/suites/motb/manifests/README.md",
            "content": "# Manifests"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn skips_manifest_detection_outside_manifests_directory() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/suites/motb/groups/g01/01-create.yaml",
            "content": "apiVersion: v1\nkind: ConfigMap"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert!(
        !issues
            .iter()
            .any(|i| i.summary.contains("Manifest created during run"))
    );
}

#[test]
fn manifest_created_during_run_output_shape() {
    let mut state = make_state();
    let block = serde_json::json!({
        "type": "tool_use",
        "id": "t1",
        "name": "Write",
        "input": {
            "file_path": "/data/runs/20260315/manifests/containerpatch.yaml",
            "content": "kind: ContainerPatch"
        }
    });
    let issues = check_tool_use_for_issues(10, &block, &mut state);
    assert_eq!(issues.len(), 1);
    let issue = &issues[0];
    assert!(!issue.fix_safety.is_fixable());
    assert_eq!(issue.fix_target.as_deref(), Some("skills/new/SKILL.md"));
    assert!(
        issue
            .fix_hint
            .as_deref()
            .is_some_and(|hint| hint.contains("suite:new"))
    );
}
