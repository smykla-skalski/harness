use super::*;
use std::path::PathBuf;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::Decision;
use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::hooks::runner_policy::TrackedHarnessSubcommand;
use crate::run::workflow::{PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState};

use super::predicates::{is_tracked_harness_command, make_target};

mod security_regressions;

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
fn denies_kubectl_without_tracked_run() {
    let c = ctx_without_run("suite:run", "kubectl get pods");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_kubectl_logs_without_tracked_run() {
    let c = ctx_without_run(
        "suite:run",
        "kubectl logs -n kuma-demo deploy/otel-collector --tail=10 2>&1",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_python_piped_after_harness_without_tracked_run() {
    let c = ctx_without_run(
        "suite:run",
        "harness run record --gid g03 --phase verify --label check \
         -- kubectl exec deploy/demo-client -- wget -qO- localhost:9901/config_dump \
         2>&1 | python3 -c \"import json, sys; print(json.load(sys.stdin))\"",
    );
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_docker_without_tracked_run() {
    let c = ctx_without_run("suite:run", "docker ps");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_helm_without_tracked_run() {
    let c = ctx_without_run("suite:run", "helm install kuma kuma/kuma");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn denies_admin_endpoint_without_tracked_run() {
    let c = ctx_without_run("suite:run", "curl localhost:9901/config_dump");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Deny);
}

#[test]
fn allows_safe_commands_without_tracked_run() {
    let c = ctx_without_run("suite:run", "echo hello world");
    let r = execute(&c).unwrap();
    assert_eq!(r.decision, Decision::Allow);
}

#[test]
fn allows_harness_wrapper_without_tracked_run() {
    let c = ctx_without_run(
        "suite:run",
        "harness run record --phase verify --label pods -- kubectl get pods",
    );
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
    let words: Vec<String> = vec!["make", "k3d/cluster/stop"]
        .into_iter()
        .map(String::from)
        .collect();
    assert_eq!(make_target(&words), Some("k3d/cluster/stop"));
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
