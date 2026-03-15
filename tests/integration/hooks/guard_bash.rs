// Tests for the guard-bash hook.
// Verifies denial of direct cluster binary usage (kubectl, kumactl, helm, docker, k3d),
// legacy scripts, shell operators, suite root creation, make targets, github sidequests,
// control file mutation, harness command chaining/looping, admin endpoint access,
// and phase-gated command restrictions after run completion.

use harness::hooks::guard_bash;
use harness::schema::Verdict;
use harness::workflow::runner::{
    self as runner_workflow, PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState,
};

use super::super::helpers::*;

// ============================================================================
// Basic denied binary tests
// ============================================================================

#[test]
fn guard_bash_denies_direct_kubectl() {
    let ctx = make_hook_context("suite:run", make_bash_payload("kubectl get pods"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

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
fn guard_bash_denies_legacy_script() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("python3 tools/record_command.py -- echo hello"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_kumactl_after_shell_op() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("ls -la /tmp/kumactl && /tmp/kumactl version 2>&1"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_kumactl_variable() {
    let ctx = make_hook_context("suite:run", make_bash_payload("$KUMACTL version"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

// kumactl is denied even when it appears in a path argument
#[test]
fn guard_bash_kumactl_listing() {
    let ctx = make_hook_context("suite:run", make_bash_payload("ls -la /tmp/kumactl"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_harness_run_kumactl() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("harness run --phase setup --label kumactl-version kumactl version"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    // Tracked harness commands allow wrapped cluster binaries
    assert_allow(&r);
}

#[test]
fn guard_bash_allows_harness_run_envoy_admin() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "harness run --phase verify --label admin-check curl localhost:9901/config_dump",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_allows_harness_envoy_capture() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "harness envoy capture --phase verify --label config-dump \
             --namespace kuma-demo --workload deploy/demo-client \
             --admin-path /config_dump",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

// ============================================================================
// Mixed kuma resource delete tests
// ============================================================================

#[test]
fn guard_bash_denies_mixed_kuma_delete() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "harness record --phase cleanup --label cleanup-g04 -- \
             kubectl delete meshopentelemetrybackend otel-runtime \
             meshmetric metrics-runtime -n kuma-system",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_mixed_kuma_delete_harness_run() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "harness run --phase cleanup --label cleanup-g04 \
             kubectl delete meshopentelemetrybackend otel-runtime \
             meshmetric metrics-runtime -n kuma-system",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_single_kuma_delete() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "harness record --phase cleanup --label cleanup-g05 -- \
             kubectl delete meshopentelemetrybackend otel-e2e -n kuma-system",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    // Tracked harness commands allow wrapped cluster binaries
    assert_allow(&r);
}

// ============================================================================
// Allow/deny pattern tests
// ============================================================================

#[test]
fn guard_bash_allows_ls_without_cluster_binary() {
    // ls is allowed because it's not a denied binary
    let ctx = make_hook_context("suite:run", make_bash_payload("ls -la /tmp"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_denies_suite_root_creation() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("mkdir -p /tmp/suites/my-new-suite/groups"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_make_k3d() {
    let ctx = make_hook_context("suite:run", make_bash_payload("make k3d/stop"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_github_sidequest() {
    let ctx = make_hook_context("suite:run", make_bash_payload("gh run view 12345"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_python_control_file() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("python3 -c 'import json; ...' run-status.json"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_redirect_run_report() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("echo '# report' > run-report.md"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_read_runner_state() {
    let ctx = make_hook_context("suite:run", make_bash_payload("cat suite-run-state.json"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_read_command_log() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("cat commands/command-log.md"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_redirect_command_log() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("echo row >> commands/command-log.md"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

// ============================================================================
// Shell chain and loop denial tests
// ============================================================================

#[test]
fn guard_bash_denies_harness_in_loop() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "for i in 01 02 03; do \
             harness apply --manifest \"g10/${i}.yaml\" --step \"g10-manifest-${i}\" || break; \
             done",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
    assert!(r.message.contains("shell chains or loops"));
}

#[test]
fn guard_bash_denies_chained_harness() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "sleep 5 && harness run --phase verify --label ctx kubectl config current-context",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_harness_record_pipe_jq() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload(
            "harness record --phase verify --label pods \
             kubectl get pods -o json | jq '.items[].metadata.name'",
        ),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    // Tracked harness commands allow wrapped cluster binaries
    assert_allow(&r);
}

// ============================================================================
// Direct binary denial tests
// ============================================================================

#[test]
fn guard_bash_denies_helm_direct() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("helm install kuma kuma/kuma"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_docker_direct() {
    let ctx = make_hook_context("suite:run", make_bash_payload("docker ps"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_denies_k3d_direct() {
    let ctx = make_hook_context("suite:run", make_bash_payload("k3d cluster list"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_allows_harness_record() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("harness record --phase verify --label test -- echo hello"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_allows_empty_command() {
    let ctx = make_hook_context("suite:run", make_bash_payload(""));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_denies_admin_endpoint_direct() {
    let ctx = make_hook_context(
        "suite:run",
        make_bash_payload("wget -qO- localhost:9901/config_dump"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

// ============================================================================
// suite:new skill tests
// ============================================================================

#[test]
fn guard_bash_author_denies_kubectl() {
    let ctx = make_hook_context("suite:new", make_bash_payload("kubectl get pods"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_author_allows_harness() {
    let ctx = make_hook_context(
        "suite:new",
        make_bash_payload("harness authoring-show --kind session"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_author_denies_admin_endpoint() {
    let ctx = make_hook_context(
        "suite:new",
        make_bash_payload("curl localhost:9901/config_dump"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_author_denies_helm() {
    let ctx = make_hook_context(
        "suite:new",
        make_bash_payload("helm install kuma kuma/kuma"),
    );
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_author_denies_docker() {
    let ctx = make_hook_context("suite:new", make_bash_payload("docker ps"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_author_denies_k3d() {
    let ctx = make_hook_context("suite:new", make_bash_payload("k3d cluster list"));
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
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
    let payload = make_bash_payload("harness cluster single-up kuma-1");
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
    let payload = make_bash_payload("harness preflight");
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
    let payload = make_bash_payload("harness cluster single-down kuma-1");
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
    let payload = make_bash_payload("harness report check");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_bash_completed_state_blocks_commands() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let state = RunnerWorkflowState {
        schema_version: 1,
        phase: RunnerPhase::Completed,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 5,
        last_event: Some("RunCompleted".to_string()),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_bash_payload("harness apply --manifest test.yaml");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_bash_completed_allows_closeout() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let state = RunnerWorkflowState {
        schema_version: 1,
        phase: RunnerPhase::Completed,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 5,
        last_event: Some("RunCompleted".to_string()),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_bash_payload("harness closeout");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_bash::execute(&ctx).unwrap();
    assert_allow(&r);
}
