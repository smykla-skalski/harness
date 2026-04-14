use super::*;

use crate::hooks::protocol::hook_result::Decision;

#[test]
fn denies_python_inline_in_suite_run() {
    let c = ctx(
        "suite:run",
        "kubectl get pods -o json | python3 -c \"import json, sys; print(json.load(sys.stdin))\"",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("do not use python"));
}

#[test]
fn denies_python_stdin_pipe() {
    let c = ctx("suite:run", "cat data.json | python3 -");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("do not use python"));
}

#[test]
fn denies_python_without_version_suffix() {
    let c = ctx("suite:create", "echo '{}' | python -c \"import json\"");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("do not use python"));
}

#[test]
fn denies_python_piped_after_harness_record() {
    let c = ctx(
        "suite:run",
        "harness run record --gid g03 --phase verify --label check \
         -- kubectl exec -n kuma-demo deploy/demo-client -c kuma-sidecar \
         -- wget -qO- localhost:9901/config_dump 2>&1 | python3 -c \"\
         import json, sys; print(json.load(sys.stdin))\"",
    );
    let r = execute(&c).unwrap();
    assert_eq!(
        r.decision,
        Decision::Deny,
        "python piped after harness record must be denied"
    );
}

#[test]
fn allows_python_version_check() {
    let c = ctx("suite:run", "python3 --version");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_python_script_file() {
    let c = ctx("suite:create", "python3 script.py");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_cat_task_output_file() {
    let c = ctx(
        "suite:run",
        "cat /private/tmp/claude-501/sessions/abc123/tasks/xyz.output",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("TaskOutput tool"));
}

#[test]
fn denies_sleep_then_cat_task_output() {
    let c = ctx(
        "suite:run",
        "sleep 120 && cat /private/tmp/claude-501/sessions/abc123/tasks/xyz.output",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("TaskOutput tool"));
}

#[test]
fn denies_task_output_glob() {
    let c = ctx("suite:run", "cat tasks/*.output");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("TaskOutput tool"));
}

#[test]
fn denies_task_b8m_prefix() {
    let c = ctx("suite:run", "cat tasks/b8m-something.output");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("TaskOutput tool"));
}

#[test]
fn allows_unrelated_cat_command() {
    let c = ctx("suite:run", "cat /tmp/some-other-file.txt");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_kubectl_in_dollar_paren_subshell() {
    let c = ctx("suite:run", "echo $(kubectl get pods)");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn denies_kumactl_in_backtick_subshell() {
    let c = ctx("suite:run", "echo `kumactl version`");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn denies_nested_subshell_kubectl() {
    let c = ctx("suite:run", "echo $(echo $(kubectl get pods))");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn denies_docker_in_subshell() {
    let c = ctx("suite:run", "result=$(docker ps -a)");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn denies_helm_in_backtick_subshell() {
    let c = ctx("suite:run", "echo `helm list`");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn denies_k3d_in_subshell() {
    let c = ctx("suite:run", "echo $(k3d cluster list)");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn denies_subshell_kubectl_in_suite_author() {
    let c = ctx("suite:create", "echo $(kubectl get pods)");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert_eq!(r.code, "KSR017");
}

#[test]
fn allows_safe_subshell_no_denied_binary() {
    let c = ctx("suite:run", "echo $(date +%Y-%m-%d)");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_harness_record_with_safe_subshell() {
    let c = ctx(
        "suite:run",
        "harness record --phase verify --label ts -- echo $(date)",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_kubectl_validate_direct() {
    let c = ctx("suite:run", "kubectl-validate manifests/");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kumactl_direct() {
    let c = ctx("suite:run", "kumactl get meshes");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_with_absolute_path() {
    let c = ctx("suite:run", "/usr/local/bin/kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_with_relative_path() {
    let c = ctx("suite:run", "./kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_docker_with_path_prefix() {
    let c = ctx("suite:run", "/usr/bin/docker run alpine");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_via_env_var_prefix() {
    let c = ctx("suite:run", "$kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_via_env_var_brace() {
    let c = ctx("suite:run", "${kubectl} get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_after_pipe() {
    let c = ctx("suite:run", "echo test | kubectl apply -f -");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_after_and_chain() {
    let c = ctx("suite:run", "sleep 1 && kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_after_or_chain() {
    let c = ctx("suite:run", "false || kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_after_semicolon() {
    let c = ctx("suite:run", "echo done; kubectl delete namespace foo");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_cluster_binary_in_unquoted_argument() {
    let c = ctx("suite:run", "echo kubectl");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_helm_as_path_argument() {
    let c = ctx("suite:run", "ls /tmp/helm");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_with_env_prefix() {
    let c = ctx("suite:run", "KUBECONFIG=/tmp/conf kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_docker_with_multiple_env_prefixes() {
    let c = ctx(
        "suite:run",
        "DOCKER_HOST=tcp://localhost:2375 DEBUG=1 docker ps",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_curl_to_envoy_admin() {
    let c = ctx("suite:run", "curl localhost:9901/config_dump");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_wget_to_envoy_clusters() {
    let c = ctx("suite:run", "wget -qO- localhost:9901/clusters");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn allows_harness_run_with_kubectl() {
    let c = ctx(
        "suite:run",
        "harness run record --phase verify --label pods -- kubectl get pods -o json",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_harness_record_with_kumactl() {
    let c = ctx(
        "suite:run",
        "harness record --phase verify --label version -- kumactl version",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_plain_echo() {
    let c = ctx("suite:run", "echo hello world");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_cat_non_control_file() {
    let c = ctx("suite:run", "cat /tmp/test-output.json");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_jq_processing() {
    let c = ctx("suite:run", "jq '.items[].metadata.name' /tmp/pods.json");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}
