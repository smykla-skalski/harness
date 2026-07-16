#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn run_records_kubectl_with_active_run_kubeconfig() {
    super::env_kubectl_tests::check_run_records_kubectl_with_active_run_kubeconfig();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn record_rewrites_kubectl_to_tracked_kubeconfig() {
    super::env_kubectl_tests::check_record_rewrites_kubectl_to_tracked_kubeconfig();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn record_rejects_kubectl_target_override() {
    super::env_kubectl_tests::check_record_rejects_kubectl_target_override();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn record_rejects_kubectl_without_tracked_cluster() {
    super::env_kubectl_tests::check_record_rejects_kubectl_without_tracked_cluster();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn record_kubectl_without_tracked_kubeconfig_fails_closed() {
    super::env_kubectl_tests::check_record_kubectl_without_tracked_kubeconfig_fails_closed();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn kumactl_build_runs_make_and_prints_binary() {
    super::env_kubectl_tests::check_kumactl_build_runs_make_and_prints_binary();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn bootstrap_command_runs_gateway_api_crd_install() {
    super::env_kubectl_tests::check_bootstrap_command_runs_gateway_api_crd_install();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn capture_uses_current_run_context() {
    super::env_kubectl_tests::check_capture_uses_current_run_context();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn record_isolates_run_context_by_session_id() {
    super::env_create_tests::check_record_isolates_run_context_by_session_id();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn create_begin_persists_suite_default_repo_root() {
    super::env_create_tests::check_create_begin_persists_suite_default_repo_root();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn create_save_accepts_inline_payload() {
    super::env_create_tests::check_create_save_accepts_inline_payload();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn create_save_accepts_stdin() {
    super::env_create_tests::check_create_save_accepts_stdin();
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn create_save_rejects_schema_missing_fields() {
    super::env_create_tests::check_create_save_rejects_schema_missing_fields();
}
