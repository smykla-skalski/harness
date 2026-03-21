use super::*;
use std::path::PathBuf;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::hooks::runner_policy::TrackedHarnessSubcommand;
use crate::run::workflow::{PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState};

use super::predicates::{is_tracked_harness_command, make_target};

fn base_ctx(skill: &str, command: &str) -> HookContext {
    HookContext::from_test_envelope(
        skill,
        HookEnvelopePayload {
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({
                "command": command,
            }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        },
    )
}

fn active_runner_state() -> RunnerWorkflowState {
    RunnerWorkflowState {
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-19T00:00:00Z".to_string(),
        transition_count: 1,
        last_event: Some("RunStarted".to_string()),
        history: Vec::new(),
    }
}

fn ctx(skill: &str, command: &str) -> HookContext {
    let mut ctx = base_ctx(skill, command);
    if skill == "suite:run" {
        ctx.run_dir = Some(PathBuf::from("/tmp/harness-test-run"));
        ctx.runner_state = Some(active_runner_state());
    }
    ctx
}

fn ctx_without_run(skill: &str, command: &str) -> HookContext {
    base_ctx(skill, command)
}

#[test]
fn denies_direct_kubectl() {
    let c = ctx("suite:run", "kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_legacy_script_via_python() {
    let c = ctx("suite:run", "python3 tools/record_command.py -- echo hello");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kumactl_path_after_shell_op() {
    let c = ctx(
        "suite:run",
        "ls -la /tmp/kumactl && /tmp/kumactl version 2>&1",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

// Catches kumactl anywhere in command words, including path-like arguments.
#[test]
fn denies_kumactl_in_path_arg() {
    let c = ctx("suite:run", "ls -la /tmp/kumactl");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn allows_kumactl_in_harness_run() {
    let c = ctx(
        "suite:run",
        "harness run record --phase setup --label kumactl-version -- kumactl version",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_harness_envoy_capture() {
    let c = ctx(
        "suite:run",
        "harness envoy capture --phase verify --label config-dump --namespace kuma-demo \
         --workload deploy/demo-client --admin-path /config_dump",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_github_without_tracked_run() {
    let c = ctx_without_run("suite:run", "gh run view 12345");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_kubectl_without_tracked_run() {
    let c = ctx_without_run("suite:run", "kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_direct_kubectl_for_suite_author() {
    let c = ctx("suite:create", "kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_rm_rf_suite_dir_for_suite_author() {
    let c = ctx(
        "suite:create",
        "rm -rf ~/.local/share/harness/suites/motb-compliance",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("mutate suite storage"));
}

#[test]
fn allows_harness_wrapper_for_suite_author() {
    let c = ctx("suite:create", "harness create-show --kind session");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_empty_command() {
    let c = ctx("suite:run", "");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_helm_direct() {
    let c = ctx("suite:run", "helm install kuma kuma/kuma");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_docker_direct() {
    let c = ctx("suite:run", "docker ps");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_k3d_direct() {
    let c = ctx("suite:run", "k3d cluster list");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn allows_harness_record() {
    let c = ctx(
        "suite:run",
        "harness record --phase verify --label test -- echo hello",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_inactive_skill() {
    let mut c = ctx("suite:run", "kubectl get pods");
    c.skill_active = false;
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_admin_endpoint_direct() {
    let c = ctx("suite:run", "wget -qO- localhost:9901/config_dump");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_mixed_kuma_resource_delete() {
    let c = ctx(
        "suite:run",
        "harness record --phase cleanup --label cleanup-g04 -- \
         kubectl delete meshopentelemetrybackend otel-runtime \
         meshmetric metrics-runtime -n kuma-system",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(
        r.message
            .contains("cleanup must not mix multiple resource kinds")
    );
}

#[test]
fn allows_single_kuma_resource_delete_via_harness_record() {
    let c = ctx(
        "suite:run",
        "harness record --phase cleanup --label cleanup-g05 -- \
         kubectl delete meshopentelemetrybackend otel-e2e -n kuma-system",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_tracked_harness_in_loop() {
    let c = ctx(
        "suite:run",
        "for i in 01 02 03; do \
         harness apply --manifest \"g10/${i}.yaml\" --step \"g10-manifest-${i}\" || break; \
         done",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("shell chains or loops"));
}

#[test]
fn denies_chained_tracked_harness() {
    let c = ctx(
        "suite:run",
        "sleep 5 && harness run record --phase verify --label ctx -- kubectl config current-context",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("run the tracked harness step directly"));
}

#[test]
fn allows_kubectl_in_harness_record_pipe() {
    let c = ctx(
        "suite:run",
        "harness record --phase verify --label pods \
         kubectl get pods -o json | jq '.items[].metadata.name'",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn make_target_extracts() {
    let words: Vec<String> = vec!["make", "k3d/stop"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(make_target(&words), Some("k3d/stop"));
}

#[test]
fn make_target_none_without_make() {
    let words: Vec<String> = vec!["echo", "hello"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(make_target(&words), None);
}

#[test]
fn is_tracked_harness_command_positive() {
    let words: Vec<String> = vec![
        "harness", "record", "--phase", "verify", "--", "kubectl", "get", "pods",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    assert!(is_tracked_harness_command(&words));

    let words: Vec<String> = vec![
        "harness", "run", "record", "--phase", "setup", "--", "kumactl", "version",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    assert!(is_tracked_harness_command(&words));
}

#[test]
fn is_tracked_harness_command_negative() {
    let words: Vec<String> = vec!["kubectl", "get", "pods"]
        .into_iter()
        .map(String::from)
        .collect();
    assert!(!is_tracked_harness_command(&words));

    let words: Vec<String> = vec!["harness", "create-show", "--kind", "session"]
        .into_iter()
        .map(String::from)
        .collect();
    assert!(!is_tracked_harness_command(&words));

    let words: Vec<String> = vec!["ls", "-la"].into_iter().map(String::from).collect();
    assert!(!is_tracked_harness_command(&words));
}

#[test]
fn is_tracked_harness_subcommand_includes_token() {
    assert!(TrackedHarnessSubcommand::is_tracked("token"));
}

#[test]
fn is_tracked_harness_subcommand_includes_service() {
    assert!(TrackedHarnessSubcommand::is_tracked("service"));
}

#[test]
fn allows_harness_token_command() {
    let c = ctx(
        "suite:run",
        "harness run kuma token dataplane --name demo --mesh default",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_harness_service_command() {
    let c = ctx(
        "suite:run",
        "harness run kuma service up demo --image kuma-dp:latest --port 5050",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn denies_python_inline_in_suite_create() {
    let c = ctx(
        "suite:create",
        "harness create-show --kind coverage | python3 -c \"import json, sys; print(json.load(sys.stdin))\"",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
    assert!(r.message.contains("do not use python"));
}

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

// --- Subshell smuggling tests ---

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

// --- Additional negative security tests (Fix 4) ---

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
