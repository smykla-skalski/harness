use std::collections::HashSet;

use crate::hooks::protocol::hook_result::Decision;

use super::*;

#[test]
fn cli_err_basic_fields() {
    let err: CliError = CliErrorKind::not_a_mapping("foo").into();
    assert_eq!(err.code(), "KSRCLI010");
    assert_eq!(err.message(), "foo must be a mapping");
    assert_eq!(err.exit_code(), 5);
    assert!(err.hint().is_none());
}

#[test]
fn cli_err_with_hint() {
    let err: CliError = CliErrorKind::MissingRunPointer.into();
    assert_eq!(err.code(), "KSRCLI005");
    assert_eq!(err.message(), "missing current run pointer");
    assert_eq!(err.hint().as_deref(), Some("Run init first."));
}

#[test]
fn cli_err_with_details_field() {
    let err = CliErrorKind::command_failed("ls -la").with_details("exit 1");
    assert_eq!(err.code(), "KSRCLI004");
    assert_eq!(err.message(), "command failed: ls -la");
    assert_eq!(err.exit_code(), 4);
    assert_eq!(err.details(), Some("exit 1"));
}

#[test]
fn cli_err_formats_message() {
    let err: CliError = CliErrorKind::missing_file("/tmp/gone.txt").into();
    assert_eq!(err.message(), "missing file: /tmp/gone.txt");
}

fn core_error_kinds() -> Vec<CliErrorKind> {
    vec![
        CliErrorKind::EmptyCommandArgs,
        CliErrorKind::missing_tools(""),
        CliErrorKind::command_failed(""),
        CliErrorKind::MissingRunPointer,
        CliErrorKind::missing_closeout_artifact(""),
        CliErrorKind::MissingStateCapture,
        CliErrorKind::VerdictPending,
        CliErrorKind::missing_run_context_value(""),
        CliErrorKind::missing_run_location(""),
        CliErrorKind::invalid_json(""),
        CliErrorKind::not_a_mapping(""),
        CliErrorKind::not_string_keys(""),
        CliErrorKind::not_a_list(""),
        CliErrorKind::not_all_strings(""),
        CliErrorKind::missing_file(""),
        CliErrorKind::MissingFrontmatter,
        CliErrorKind::UnterminatedFrontmatter,
        CliErrorKind::path_not_found(""),
        CliErrorKind::missing_fields("", ""),
        CliErrorKind::field_type_mismatch("", "", ""),
        CliErrorKind::missing_sections("", ""),
        CliErrorKind::no_resource_kinds(""),
        CliErrorKind::route_not_found(""),
        CliErrorKind::GatewayVersionMissing,
        CliErrorKind::GatewayCrdsMissing,
        CliErrorKind::gateway_download_empty(""),
        CliErrorKind::KumactlNotFound,
    ]
}

fn extended_error_kinds() -> Vec<CliErrorKind> {
    vec![
        CliErrorKind::report_line_limit("", ""),
        CliErrorKind::report_code_block_limit("", ""),
        CliErrorKind::CreateSessionMissing,
        CliErrorKind::CreatePayloadMissing,
        CliErrorKind::create_payload_invalid("", ""),
        CliErrorKind::create_show_kind_missing(""),
        CliErrorKind::create_validate_failed(""),
        CliErrorKind::KubectlValidateDecisionRequired,
        CliErrorKind::KubectlValidateUnavailable,
        CliErrorKind::TrackedKubectlRequired,
        CliErrorKind::kubectl_target_override_forbidden(""),
        CliErrorKind::unknown_tracked_cluster("", ""),
        CliErrorKind::non_local_kubeconfig(""),
        CliErrorKind::run_group_already_recorded(""),
        CliErrorKind::run_group_not_found(""),
        CliErrorKind::envoy_config_type_not_found(""),
        CliErrorKind::envoy_capture_args_required(""),
        CliErrorKind::evidence_label_not_found(""),
        CliErrorKind::ReportGroupEvidenceRequired,
        CliErrorKind::amendments_required(""),
        CliErrorKind::create_suite_dir_exists(""),
        CliErrorKind::run_dir_exists(""),
        CliErrorKind::unsafe_name(""),
        CliErrorKind::MissingRunStatus,
        CliErrorKind::MarkdownShapeMismatch,
        CliErrorKind::container_start_failed(""),
        CliErrorKind::container_not_found(""),
        CliErrorKind::cp_api_unreachable(""),
        CliErrorKind::token_generation_failed(""),
        CliErrorKind::docker_network_failed(""),
        CliErrorKind::compose_file_failed(""),
        CliErrorKind::image_build_failed(""),
        CliErrorKind::template_render(""),
        CliErrorKind::service_readiness_timeout(""),
        CliErrorKind::io(""),
        CliErrorKind::serialize(""),
        CliErrorKind::hook_payload_invalid(""),
        CliErrorKind::workflow_io(""),
        CliErrorKind::workflow_parse(""),
        CliErrorKind::workflow_version(""),
        CliErrorKind::concurrent_modification(""),
        CliErrorKind::workflow_serialize(""),
        CliErrorKind::json_parse(""),
        CliErrorKind::cluster_error(""),
        CliErrorKind::usage_error(""),
        CliErrorKind::session_not_found(""),
        CliErrorKind::session_parse_error(""),
        CliErrorKind::session_ambiguous(""),
        CliErrorKind::universal_validation_failed(""),
        CliErrorKind::invalid_transition(""),
    ]
}

#[test]
fn cli_err_all_codes_unique() {
    let mut all_kinds = core_error_kinds();
    all_kinds.extend(extended_error_kinds());
    let codes: Vec<&str> = all_kinds.iter().map(CliErrorKind::code).collect();
    let unique: HashSet<&str> = codes.iter().copied().collect();
    assert_eq!(codes.len(), unique.len(), "duplicate error codes found");
}

#[test]
fn cli_err_no_args_message() {
    let err: CliError = CliErrorKind::MissingFrontmatter.into();
    assert_eq!(err.message(), "missing YAML frontmatter");
}

#[test]
fn cli_err_hint_formats_correctly() {
    let err: CliError = CliErrorKind::KumactlNotFound.into();
    assert_eq!(err.hint().as_deref(), Some("Build kumactl first."));
}

#[test]
fn service_readiness_timeout_has_hint() {
    let err: CliError = CliErrorKind::service_readiness_timeout("demo-svc").into();
    let hint = err.hint().expect("should have a hint");
    assert!(hint.contains("harness run kuma service down demo-svc"));
}

#[test]
fn cli_err_report_line_limit() {
    let err: CliError = CliErrorKind::report_line_limit("500", "400").into();
    assert_eq!(err.message(), "report exceeds line limit: 500>400");
    assert_eq!(err.exit_code(), 1);
}

#[test]
fn cli_err_closeout_codes_are_distinct() {
    let codes: HashSet<&str> = [
        CliErrorKind::missing_closeout_artifact("").code(),
        CliErrorKind::MissingStateCapture.code(),
        CliErrorKind::VerdictPending.code(),
    ]
    .into_iter()
    .collect();
    assert_eq!(codes.len(), 3);
}

#[test]
fn cli_err_markdown_shape_mismatch() {
    let err: CliError = CliErrorKind::MarkdownShapeMismatch.into();
    assert_eq!(err.code(), "KSRCLI999");
    assert_eq!(err.exit_code(), 6);
}

#[test]
fn cli_err_display_trait() {
    let err: CliError = CliErrorKind::missing_tools("kubectl").into();
    let displayed = format!("{err}");
    assert_eq!(displayed, "[KSRCLI002] missing required tools: kubectl");
}

#[test]
fn render_error_includes_hint_and_details() {
    let err = CliErrorKind::MissingRunPointer.with_details("stack");
    let rendered = render_error(&err);
    assert!(rendered.contains("ERROR [KSRCLI005] missing current run pointer"));
    assert!(rendered.contains("Hint: Run init first."));
    assert!(rendered.contains("stack"));
}

#[test]
fn render_error_without_hint_or_details() {
    let err: CliError = CliErrorKind::io("oops").into();
    let rendered = render_error(&err);
    assert!(rendered.contains("ERROR [IO001] oops"));
    assert!(!rendered.contains("Hint:"));
    assert!(!rendered.contains("Details:"));
}

#[test]
fn hook_msg_deny_result() {
    let result = HookMessage::ClusterBinary.into_result();
    assert_eq!(result.decision, Decision::Deny);
    assert_eq!(result.code, "KSR005");
    assert!(result.message.contains("`harness run ...`"));
}

#[test]
fn hook_msg_warn_result() {
    let result = HookMessage::missing_artifact("preflight.py", "/tmp/x").into_result();
    assert_eq!(result.decision, Decision::Warn);
    assert_eq!(result.code, "KSR006");
    assert!(result.message.contains("preflight.py"));
    assert!(result.message.contains("/tmp/x"));
}

#[test]
fn hook_msg_info_result() {
    let result = HookMessage::run_verdict("pass").into_result();
    assert_eq!(result.decision, Decision::Info);
    assert_eq!(result.code, "KSR012");
    assert!(result.message.contains("pass"));
}

#[test]
fn hook_msg_deny_with_fields() {
    let result = HookMessage::write_outside_run("/bad/path").into_result();
    assert_eq!(result.decision, Decision::Deny);
    assert!(result.message.contains("/bad/path"));
}

#[test]
fn hook_msg_no_fields_message() {
    let result = HookMessage::GroupsNotList.into_result();
    assert_eq!(result.message, "suite groups must be a list");
}

#[test]
fn hook_msg_bug_found_gate_required() {
    let result = HookMessage::bug_found_gate_required("harness apply").into_result();
    assert_eq!(result.decision, Decision::Deny);
    assert_eq!(result.code, "KSR016");
    assert!(result.message.contains("harness apply"));
    assert!(result.message.contains("bug-found gate"));
}

#[test]
fn snapshot_render_error_with_hint_and_details() {
    let err = CliErrorKind::MissingRunPointer.with_details("checked /tmp/ctx/current-run.json");
    let rendered = render_error(&err);
    insta::assert_snapshot!(rendered);
}

#[test]
fn snapshot_render_error_missing_file() {
    let err: CliError = CliErrorKind::missing_file("/tmp/runs/run-1/run-metadata.json").into();
    let rendered = render_error(&err);
    insta::assert_snapshot!(rendered);
}

#[test]
fn snapshot_render_error_command_failed() {
    let err = CliErrorKind::command_failed("kubectl apply -f manifest.yaml")
        .with_details("error: the path \"manifest.yaml\" does not exist");
    let rendered = render_error(&err);
    insta::assert_snapshot!(rendered);
}

#[test]
fn snapshot_hook_result_deny_json() {
    use crate::hooks::protocol::hook_result::HookResult;

    let result = HookResult::deny("KSR005", "Direct cluster binary access is not allowed.");
    let json = serde_json::to_string_pretty(&result).expect("serialize hook result");
    insta::assert_snapshot!(json);
}

#[test]
fn snapshot_hook_result_warn_json() {
    use crate::hooks::protocol::hook_result::HookResult;

    let result = HookResult::warn("KSR006", "Artifact missing: preflight.json");
    let json = serde_json::to_string_pretty(&result).expect("serialize hook result");
    insta::assert_snapshot!(json);
}

#[test]
fn snapshot_hook_result_info_json() {
    use crate::hooks::protocol::hook_result::HookResult;

    let result = HookResult::info("KSR012", "Run verdict: pass");
    let json = serde_json::to_string_pretty(&result).expect("serialize hook result");
    insta::assert_snapshot!(json);
}

#[test]
fn hook_message_count() {
    let all_hooks: Vec<HookMessage> = vec![
        HookMessage::ClusterBinary,
        HookMessage::AdminEndpoint,
        HookMessage::MissingStateCapture,
        HookMessage::VerdictPending,
        HookMessage::write_outside_run(""),
        HookMessage::runner_state_invalid(""),
        HookMessage::runner_flow_required("", ""),
        HookMessage::preflight_reply_invalid(""),
        HookMessage::write_outside_suite(""),
        HookMessage::approval_state_invalid(""),
        HookMessage::approval_required("", ""),
        HookMessage::GroupsNotList,
        HookMessage::BaselinesNotList,
        HookMessage::suite_incomplete(""),
        HookMessage::validator_gate_required(""),
        HookMessage::validator_install_failed(""),
        HookMessage::validator_gate_unexpected(""),
        HookMessage::bug_found_gate_required(""),
        HookMessage::missing_artifact("", ""),
        HookMessage::RunPreflight,
        HookMessage::PreflightMissing,
        HookMessage::CodeReaderFormat,
        HookMessage::reader_missing_sections(""),
        HookMessage::ReaderOversizedBlock,
        HookMessage::SuiteRunnerTracked,
        HookMessage::run_verdict(""),
        HookMessage::SuiteCreateTracked,
    ];
    assert_eq!(all_hooks.len(), 27);
}
