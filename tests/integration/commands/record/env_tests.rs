use std::sync::PoisonError;

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn env_dependent_tests() {
    let _lock = super::super::super::helpers::ENV_LOCK
        .lock()
        .unwrap_or_else(PoisonError::into_inner);

    super::env_kubectl_tests::check_run_records_kubectl_with_active_run_kubeconfig();
    super::env_kubectl_tests::check_record_rewrites_kubectl_to_tracked_kubeconfig();
    super::env_kubectl_tests::check_record_rejects_kubectl_target_override();
    super::env_kubectl_tests::check_record_rejects_kubectl_without_tracked_cluster();
    super::env_kubectl_tests::check_record_kubectl_without_tracked_kubeconfig_fails_closed();
    super::env_kubectl_tests::check_kumactl_build_runs_make_and_prints_binary();
    super::env_kubectl_tests::check_bootstrap_command_runs_gateway_api_crd_install();
    super::env_kubectl_tests::check_capture_uses_current_run_context();
    super::env_create_tests::check_record_isolates_run_context_by_session_id();
    super::env_create_tests::check_create_begin_persists_suite_default_repo_root();
    super::env_create_tests::check_create_save_accepts_inline_payload();
    super::env_create_tests::check_create_save_accepts_stdin();
    super::env_create_tests::check_create_save_rejects_schema_missing_fields();
}
