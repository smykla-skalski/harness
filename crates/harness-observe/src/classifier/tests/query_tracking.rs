use super::*;

// ─── Repeated kubectl query tests ──────────────────────────────────

#[test]
fn detects_repeated_kubectl_get_for_same_resource() {
    let mut state = make_state();
    let commands = [
        "kubectl get crd meshretries.kuma.io -o json | jq '.spec.versions'",
        "kubectl get crd meshretries.kuma.io -o json | jq '.spec.names'",
        "kubectl get crd meshretries.kuma.io -o json | jq '.status'",
    ];
    for (index, command) in commands.iter().enumerate() {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": command }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        if index < 2 {
            assert!(
                !issues
                    .iter()
                    .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
                "should not flag on query {index}"
            );
        } else {
            assert!(
                issues
                    .iter()
                    .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
                "should flag on third query"
            );
        }
    }
}

#[test]
fn no_flag_for_different_kubectl_resources() {
    let mut state = make_state();
    let commands = [
        "kubectl get crd meshretries.kuma.io -o json",
        "kubectl get crd meshtimeouts.kuma.io -o json",
        "kubectl get crd meshcircuitbreakers.kuma.io -o json",
    ];
    for (index, command) in commands.iter().enumerate() {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": command }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        assert!(
            !issues
                .iter()
                .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
            "different resources should not trigger flag"
        );
    }
}

#[test]
fn kubectl_queries_outside_window_do_not_trigger() {
    let mut state = make_state();
    // Space queries far apart so they fall outside the 20-line window
    let lines = [10, 40, 70];
    for (index, line) in lines.iter().enumerate() {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "kubectl get crd meshretries.kuma.io -o json" }
        });
        let issues = check_tool_use_for_issues(*line, &block, &mut state);
        assert!(
            !issues
                .iter()
                .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
            "queries outside window should not trigger flag"
        );
    }
}

#[test]
fn kubectl_describe_also_tracked() {
    let mut state = make_state();
    for index in 0..3 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "kubectl describe pod my-pod -n kuma-system" }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        if index == 2 {
            assert!(
                issues
                    .iter()
                    .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
                "describe should be tracked too"
            );
        }
    }
}

#[test]
fn non_kubectl_commands_ignored_by_query_tracker() {
    let mut state = make_state();
    for index in 0..5 {
        let block = serde_json::json!({
            "type": "tool_use",
            "id": format!("t{index}"),
            "name": "Bash",
            "input": { "command": "harness record --label test -- kubectl get pods" }
        });
        let issues = check_tool_use_for_issues(10 + index, &block, &mut state);
        assert!(
            !issues
                .iter()
                .any(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource),
            "harness record wrapper should not produce false positives"
        );
    }
}

#[test]
fn repeated_kubectl_query_output_shape() {
    warm_repeated_kubectl_query_state();
    // Re-run to get issues on the 3rd (dedup means the first emit sticks)
    let all_issues = collect_repeated_kubectl_query_issues();
    let issue = all_issues
        .iter()
        .find(|i| i.code == IssueCode::RepeatedKubectlQueryForSameResource)
        .expect("should have emitted issue");
    assert_eq!(issue.category, IssueCategory::UnexpectedBehavior);
    assert_eq!(issue.severity, IssueSeverity::Low);
    assert!(!issue.fix_safety.is_fixable());
    assert!(issue.summary.contains("dump once"));
    assert!(issue.details.contains("meshretries"));
}

#[test]
fn extract_kubectl_target_strips_namespace_and_output_flags() {
    use super::super::tool_checks::extract_kubectl_query_target;
    let target = extract_kubectl_query_target(
        "kubectl get pod my-pod -n kuma-system -o json | jq '.status'",
    );
    assert_eq!(target.as_deref(), Some("get pod my-pod"));
}

#[test]
fn extract_kubectl_target_returns_none_for_non_query() {
    use super::super::tool_checks::extract_kubectl_query_target;
    assert!(extract_kubectl_query_target("kubectl apply -f manifest.yaml").is_none());
    assert!(extract_kubectl_query_target("ls -la /tmp").is_none());
}
