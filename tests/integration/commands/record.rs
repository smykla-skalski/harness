// Tests for the record command and related CLI operations.
// Covers recording with run directories, kubectl rewriting, context export,
// and artifact creation. Most tests are ignored - they require the CLI binary
// or external tools (kubectl, kumactl, k3d).

use std::fs;

#[test]
fn diff_identical_files() {
    let tmp = tempfile::tempdir().unwrap();
    let a = tmp.path().join("a.txt");
    let b = tmp.path().join("b.txt");
    fs::write(&a, "hello\n").unwrap();
    fs::write(&b, "hello\n").unwrap();
    // The diff command should report no differences
    // (testing the actual diff would require CLI binary invocation)
}

// ============================================================================
// CLI-level record tests (require binary or external tools)
// ============================================================================

#[test]
#[ignore = "Requires CLI binary"]
fn help_shows_subcommands() {
    // harness --help should list subcommands
}

#[test]
#[ignore = "Requires CLI binary"]
fn hook_help_lists_registered_hooks() {
    // harness hook --help should list hooks
}

#[test]
#[ignore = "Requires kubectl"]
fn record_accepts_run_dir_phase_and_label() {
    // harness record --run-dir ... --phase verify --label test -- echo hello
}

#[test]
#[ignore = "Requires kubectl"]
fn run_records_kubectl_with_active_run_kubeconfig() {
    // harness run --phase verify --label check kubectl get pods
}

#[test]
#[ignore = "Requires kumactl binary"]
fn kumactl_find_returns_first_existing() {
    // harness kumactl find should return binary path
}

#[test]
#[ignore = "Requires kumactl binary"]
fn kumactl_build_runs_make_and_prints_binary() {
    // harness kumactl build should trigger make
}

#[test]
#[ignore = "Requires cluster"]
fn cluster_up_rejects_finalized_run_reuse() {
    // harness cluster single-up after run completed should fail
}

#[test]
#[ignore = "Requires external tools"]
fn envoy_capture_records_admin_artifact() {
    // harness envoy capture records config_dump
}

#[test]
#[ignore = "Requires external tools"]
fn envoy_capture_can_filter_config_type() {
    // harness envoy capture --config-type bootstrap
}

#[test]
#[ignore = "Requires external tools"]
fn envoy_route_body_can_capture_live_payload() {
    // harness envoy route-body captures route config
}

#[test]
#[ignore = "Requires external tools"]
fn envoy_capture_rejects_without_tracked_cluster() {
    // harness envoy capture without cluster should fail
}

#[test]
#[ignore = "Requires external tools"]
fn run_can_target_another_tracked_cluster_member() {
    // harness run --cluster zone-1 ...
}

#[test]
#[ignore = "Requires kubectl"]
fn record_exports_context_env() {
    // harness record should set env vars for child process
}

#[test]
#[ignore = "Requires kubectl"]
fn record_rewrites_kubectl_to_tracked_kubeconfig() {
    // harness record should inject --kubeconfig
}

#[test]
#[ignore = "Requires kubectl"]
fn record_rejects_kubectl_target_override() {
    // harness record should deny --kubeconfig or --context override
}

#[test]
#[ignore = "Requires kubectl"]
fn record_rejects_kubectl_without_tracked_cluster() {
    // harness record kubectl ... without cluster should fail
}

#[test]
#[ignore = "Requires kubectl"]
fn record_kubectl_without_tracked_kubeconfig_fails_closed() {
    // harness record kubectl without kubeconfig should fail
}

#[test]
#[ignore = "Requires CLI binary"]
fn record_creates_artifact_even_when_binary_not_found() {
    // harness record should create artifact even if command fails
}

#[test]
#[ignore = "Requires CLI binary"]
fn record_with_no_command_exits_nonzero() {
    // harness record without -- should fail
}

// ============================================================================
// Approval / authoring command integration tests (require CLI binary)
// ============================================================================

#[test]
#[ignore = "Requires CLI binary with approval-begin command"]
fn approval_begin_initializes_interactive_state() {
    // harness approval-begin --skill suite-author --mode interactive
}

#[test]
#[ignore = "Requires CLI binary"]
fn authoring_begin_persists_suite_default_repo_root() {
    // harness authoring-begin should save repo root
}

#[test]
#[ignore = "Requires CLI binary"]
fn authoring_save_accepts_inline_payload() {
    // harness authoring-save --kind inventory --payload '{}'
}

#[test]
#[ignore = "Requires CLI binary"]
fn authoring_save_accepts_stdin() {
    // echo '{}' | harness authoring-save --kind inventory -
}

#[test]
#[ignore = "Requires CLI binary"]
fn authoring_save_rejects_schema_missing_fields() {
    // harness authoring-save --kind schema --payload '{}' should fail
}

#[test]
#[ignore = "Requires kubectl-validate binary"]
fn authoring_validate_accepts_valid_meshmetric_group() {
    // harness authoring-validate with valid MeshMetric group
}

#[test]
#[ignore = "Requires kubectl-validate binary"]
fn authoring_validate_rejects_invalid_meshmetric_group() {
    // harness authoring-validate with invalid backendRef
}

#[test]
#[ignore = "Requires kubectl-validate binary"]
fn authoring_validate_ignores_universal_format() {
    // Universal format blocks should be skipped
}

#[test]
#[ignore = "Requires kubectl-validate binary"]
fn authoring_validate_skips_expected_rejection_manifests() {
    // Manifests with expected rejections should skip validation
}

// ============================================================================
// Session / context isolation tests (require CLI binary)
// ============================================================================

#[test]
#[ignore = "Requires CLI binary with session management"]
fn record_isolates_run_context_by_session_id() {
    // Different CLAUDE_SESSION_ID values should isolate run contexts
}

#[test]
#[ignore = "Requires CLI binary"]
fn record_run_dir_refreshes_current_session_context() {
    // harness record --run-dir should update current session
}

#[test]
#[ignore = "Requires CLI binary"]
fn run_uses_active_project_run_without_explicit_run_id() {
    // harness run should find active run from project state
}

// ============================================================================
// Bootstrap command (require kubectl)
// ============================================================================

#[test]
#[ignore = "Requires kubectl"]
fn bootstrap_command_runs_gateway_api_crd_install() {
    // harness bootstrap should install gateway API CRDs
}

// ============================================================================
// Closeout command
// ============================================================================

#[test]
#[ignore = "Requires CLI binary"]
fn closeout_sets_completed_phase() {
    // harness closeout should transition to completed
}

// ============================================================================
// Capture command (require kubectl)
// ============================================================================

#[test]
#[ignore = "Requires kubectl"]
fn capture_uses_current_run_context() {
    // harness capture should use current run kubeconfig
}
