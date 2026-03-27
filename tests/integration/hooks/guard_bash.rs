// Tests for the guard-bash hook.
// Verifies denial of direct cluster binary usage (kubectl, kumactl, helm, docker, k3d),
// legacy scripts, shell operators, suite root creation, make targets, github sidequests,
// control file mutation, harness command chaining/looping, admin endpoint access,
// and phase-gated command restrictions after run completion.

use harness::hooks::guard_bash;
use harness::hooks::hook_result::HookResult;
use harness::run::Verdict;
use harness::run::workflow::{
    self as runner_workflow, PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState,
};

use super::super::helpers::*;

const GUARD_BASH_PAYLOAD_CASES: &[(&str, &str, bool)] = &[
    ("suite:run", "kubectl get pods", false),
    (
        "suite:run",
        "python3 tools/record_command.py -- echo hello",
        false,
    ),
    (
        "suite:run",
        "ls -la /tmp/kumactl && /tmp/kumactl version 2>&1",
        false,
    ),
    ("suite:run", "$KUMACTL version", false),
    ("suite:run", "ls -la /tmp/kumactl", false),
    (
        "suite:run",
        "harness run record --phase setup --label kumactl-version -- kumactl version",
        true,
    ),
    (
        "suite:run",
        "harness run record --phase verify --label admin-check -- curl localhost:9901/config_dump",
        true,
    ),
    (
        "suite:run",
        "harness envoy capture --phase verify --label config-dump \
         --namespace kuma-demo --workload deploy/demo-client --admin-path /config_dump",
        true,
    ),
    (
        "suite:run",
        "harness record --phase cleanup --label cleanup-g04 -- \
         kubectl delete meshopentelemetrybackend otel-runtime \
         meshmetric metrics-runtime -n kuma-system",
        false,
    ),
    (
        "suite:run",
        "harness run record --phase cleanup --label cleanup-g04 -- \
         kubectl delete meshopentelemetrybackend otel-runtime \
         meshmetric metrics-runtime -n kuma-system",
        false,
    ),
    (
        "suite:run",
        "harness record --phase cleanup --label cleanup-g05 -- \
         kubectl delete meshopentelemetrybackend otel-e2e -n kuma-system",
        true,
    ),
    ("suite:run", "ls -la /tmp", true),
    (
        "suite:run",
        "mkdir -p /tmp/suites/my-new-suite/groups",
        false,
    ),
    ("suite:run", "make k3d/cluster/stop", false),
    ("suite:run", "gh run view 12345", false),
    (
        "suite:run",
        "python3 -c 'import json; ...' run-status.json",
        false,
    ),
    ("suite:run", "echo '# report' > run-report.md", false),
    ("suite:run", "cat suite-run-state.json", false),
    ("suite:run", "cat commands/command-log.md", false),
    ("suite:run", "echo row >> commands/command-log.md", false),
    (
        "suite:run",
        "sleep 5 && harness run record --phase verify --label ctx -- kubectl config current-context",
        false,
    ),
    (
        "suite:run",
        "harness record --phase verify --label pods \
         kubectl get pods -o json | jq '.items[].metadata.name'",
        true,
    ),
    ("suite:run", "helm install kuma kuma/kuma", false),
    ("suite:run", "docker ps", false),
    ("suite:run", "k3d cluster list", false),
    (
        "suite:run",
        "harness record --phase verify --label test -- echo hello",
        true,
    ),
    ("suite:run", "", true),
    ("suite:run", "wget -qO- localhost:9901/config_dump", false),
    ("suite:create", "kubectl get pods", false),
    ("suite:create", "harness create show --kind session", true),
    ("suite:create", "curl localhost:9901/config_dump", false),
    ("suite:create", "helm install kuma kuma/kuma", false),
    ("suite:create", "docker ps", false),
    ("suite:create", "k3d cluster list", false),
];

fn execute_payload_case(skill: &str, command: &str, case_idx: usize) -> HookResult {
    if skill == "suite:run" {
        let tmp = tempfile::tempdir().unwrap();
        let run_dir = init_run(
            tmp.path(),
            &format!("guard-bash-case-{case_idx}"),
            "single-zone",
        );
        let ctx = make_hook_context_with_run(skill, make_bash_payload(command), &run_dir);
        return guard_bash::execute(&ctx).unwrap();
    }
    let ctx = make_hook_context(skill, make_bash_payload(command));
    guard_bash::execute(&ctx).unwrap()
}

// ============================================================================
// Simple allow/deny payloads (table-driven)
// ============================================================================

#[test]
fn guard_bash_payloads() {
    for (case_idx, &(skill, command, should_allow)) in GUARD_BASH_PAYLOAD_CASES.iter().enumerate() {
        let r = execute_payload_case(skill, command, case_idx);
        if should_allow {
            assert_allow(&r);
        } else {
            assert_deny(&r);
        }
    }
}

#[test]
fn guard_bash_denies_cluster_binaries_even_without_tracked_run() {
    for command in [
        "kubectl get pods",
        "curl localhost:9901/config_dump",
        "python3 -c 'print(1)'",
    ] {
        let ctx = make_hook_context("suite:run", make_bash_payload(command));
        let r = guard_bash::execute(&ctx).unwrap();
        assert_deny(&r);
    }
}

#[test]
fn guard_bash_allows_safe_commands_without_tracked_run() {
    for command in ["gh pr checks 12345", "echo hello", "ls -la"] {
        let ctx = make_hook_context("suite:run", make_bash_payload(command));
        let r = guard_bash::execute(&ctx).unwrap();
        assert_allow(&r);
    }
}

// ============================================================================
// Tests with specific message assertions or special setup
// ============================================================================

#[test]
fn guard_bash_ignores_inactive_skill() {
    let mut ctx = make_hook_context("suite:run", make_bash_payload("kubectl get pods"));
    ctx.skill_active = false;
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_hook_structured_denial_invalid_payload() {
    // Empty payload should result in allow (no command to deny)
    let ctx = make_hook_context("suite:run", make_empty_payload());
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_denies_harness_in_loop() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-loop", "single-zone");
    let ctx = make_hook_context_with_run(
        "suite:run",
        make_bash_payload(
            "for i in 01 02 03; do \
             harness run apply --manifest \"g10/${i}.yaml\" --step \"g10-manifest-${i}\" || break; \
             done",
        ),
        &run_dir,
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
    assert!(r.message.contains("shell chains or loops"));
}

// ============================================================================
// Phase-gated tests (after run completion)
// ============================================================================

#[test]
fn guard_bash_denies_rebootstrap_after_completed() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    write_run_status(&run_dir, &status);
    let payload = make_bash_payload("harness setup kuma cluster single-up kuma-1");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_continuation_after_completed() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    write_run_status(&run_dir, &status);
    let payload = make_bash_payload("harness run preflight");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_allows_cluster_down_after_completed() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    write_run_status(&run_dir, &status);
    let payload = make_bash_payload("harness setup kuma cluster single-down kuma-1");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_allows_report_check_after_completed() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    write_run_status(&run_dir, &status);
    let payload = make_bash_payload("harness run report check");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_denies_github_sidequest_with_active_run() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-gh", "single-zone");
    let payload = make_bash_payload("gh pr checks 12345");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
    assert!(r.message.contains("GitHub workflows"));
}

#[test]
fn guard_bash_completed_state_blocks_commands() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let state = RunnerWorkflowState {
        phase: RunnerPhase::Completed,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 5,
        last_event: Some("RunCompleted".to_string()),
        history: Vec::new(),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_bash_payload("harness run apply --manifest test.yaml");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_completed_allows_closeout() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let state = RunnerWorkflowState {
        phase: RunnerPhase::Completed,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 5,
        last_event: Some("RunCompleted".to_string()),
        history: Vec::new(),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_bash_payload("harness closeout");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}
