use super::*;

#[test]
fn command_heads_basic() {
    let words: Vec<String> = vec!["kubectl", "get", "pods"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(command_heads(&words), vec!["kubectl"]);
}

#[test]
fn command_heads_with_pipe() {
    let words: Vec<String> = vec!["echo", "hello", "|", "grep", "hello"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(command_heads(&words), vec!["echo", "grep"]);
}

#[test]
fn command_heads_with_env_var() {
    let words: Vec<String> = vec!["FOO=bar", "kubectl", "get", "pods"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(command_heads(&words), vec!["kubectl"]);
}

#[test]
fn normalized_binary_name_strips_path() {
    assert_eq!(normalized_binary_name("/usr/bin/kubectl"), "kubectl");
}

#[test]
fn normalized_binary_name_strips_dollar() {
    assert_eq!(normalized_binary_name("$KUMACTL"), "kumactl");
    assert_eq!(normalized_binary_name("${KUMACTL}"), "kumactl");
}

#[test]
fn is_env_assignment_positive() {
    assert!(is_env_assignment("FOO=bar"));
    assert!(is_env_assignment("PATH=/usr/bin"));
}

#[test]
fn is_env_assignment_negative() {
    assert!(!is_env_assignment("kubectl"));
    assert!(!is_env_assignment("=value"));
}

#[test]
fn parsed_command_extracts_harness_invocation() {
    let parsed =
        ParsedCommand::parse("KUBECONFIG=/tmp/conf harness report group --gid g01").unwrap();
    assert_eq!(parsed.heads(), ["harness"]);
    assert_eq!(parsed.harness_invocations().count(), 1);
    let invocation = parsed.first_harness_invocation().unwrap();
    assert_eq!(invocation.head(), "harness");
    assert_eq!(invocation.subcommand(), Some("report"));
    assert_eq!(invocation.gid(), Some("g01"));
}

#[test]
fn parsed_command_extracts_grouped_harness_invocation() {
    let parsed =
        ParsedCommand::parse("KUBECONFIG=/tmp/conf harness run report group --gid g01").unwrap();
    let invocation = parsed.first_harness_invocation().unwrap();
    assert_eq!(invocation.group(), Some("run"));
    assert_eq!(invocation.subcommand(), Some("report"));
    assert_eq!(invocation.command_label(), "harness run report");
    assert_eq!(invocation.gid(), Some("g01"));
}

#[test]
fn parsed_command_extracts_namespaced_harness_invocation() {
    let parsed =
        ParsedCommand::parse("harness run kuma token dataplane --name demo --mesh default")
            .unwrap();
    let invocation = parsed.first_harness_invocation().unwrap();
    assert_eq!(invocation.group(), Some("run"));
    assert_eq!(invocation.subcommand(), Some("token"));
    assert_eq!(invocation.command_label(), "harness run kuma token");
}

#[test]
fn semantic_harness_tail_strips_group_prefix() {
    let grouped = ["harness", "setup", "cluster", "single-up"];
    assert_eq!(
        semantic_harness_tail(&grouped).unwrap(),
        ["cluster", "single-up"]
    );
    let namespaced = ["harness", "run", "kuma", "token", "dataplane"];
    assert_eq!(
        semantic_harness_tail(&namespaced).unwrap(),
        ["token", "dataplane"]
    );
    let flat = ["harness", "report", "group"];
    assert_eq!(semantic_harness_tail(&flat).unwrap(), ["report", "group"]);
}

#[test]
fn normalized_binary_name_strips_dollar_paren() {
    assert_eq!(normalized_binary_name("$(kubectl"), "kubectl");
    assert_eq!(normalized_binary_name("$(kubectl)"), "kubectl");
}

#[test]
fn normalized_binary_name_strips_backticks() {
    assert_eq!(normalized_binary_name("`kumactl`"), "kumactl");
    assert_eq!(normalized_binary_name("`kumactl"), "kumactl");
}

#[test]
fn normalized_binary_name_strips_nested_subshell() {
    assert_eq!(normalized_binary_name("$($(kubectl)"), "kubectl");
}
