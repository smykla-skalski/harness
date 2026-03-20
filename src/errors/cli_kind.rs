use std::borrow::Cow;

use super::{
    AuthoringObserveError, CliError, CliErrorKind, CommonError, RunSetupError, WorkflowError,
};

#[allow(non_upper_case_globals)]
impl CliErrorKind {
    pub const EmptyCommandArgs: Self = Self::Common(CommonError::EmptyCommandArgs);
    pub const MissingRunPointer: Self = Self::RunSetup(RunSetupError::MissingRunPointer);
    pub const MissingStateCapture: Self = Self::RunSetup(RunSetupError::MissingStateCapture);
    pub const VerdictPending: Self = Self::RunSetup(RunSetupError::VerdictPending);
    pub const MissingFrontmatter: Self = Self::Common(CommonError::MissingFrontmatter);
    pub const UnterminatedFrontmatter: Self = Self::Common(CommonError::UnterminatedFrontmatter);
    pub const MarkdownShapeMismatch: Self = Self::Common(CommonError::MarkdownShapeMismatch);
    pub const GatewayVersionMissing: Self = Self::RunSetup(RunSetupError::GatewayVersionMissing);
    pub const GatewayCrdsMissing: Self = Self::RunSetup(RunSetupError::GatewayCrdsMissing);
    pub const KumactlNotFound: Self = Self::RunSetup(RunSetupError::KumactlNotFound);
    pub const ReportGroupEvidenceRequired: Self =
        Self::RunSetup(RunSetupError::ReportGroupEvidenceRequired);
    pub const AuthoringSessionMissing: Self =
        Self::AuthoringObserve(AuthoringObserveError::AuthoringSessionMissing);
    pub const AuthoringPayloadMissing: Self =
        Self::AuthoringObserve(AuthoringObserveError::AuthoringPayloadMissing);
    pub const KubectlValidateDecisionRequired: Self =
        Self::AuthoringObserve(AuthoringObserveError::KubectlValidateDecisionRequired);
    pub const KubectlValidateUnavailable: Self =
        Self::AuthoringObserve(AuthoringObserveError::KubectlValidateUnavailable);
    pub const TrackedKubectlRequired: Self = Self::RunSetup(RunSetupError::TrackedKubectlRequired);
    pub const MissingRunStatus: Self = Self::RunSetup(RunSetupError::MissingRunStatus);
}

impl CliErrorKind {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::Common(error) => error.code(),
            Self::RunSetup(error) => error.code(),
            Self::AuthoringObserve(error) => error.code(),
            Self::Workflow(error) => error.code(),
        }
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Common(error) => error.exit_code(),
            Self::RunSetup(error) => error.exit_code(),
            Self::AuthoringObserve(error) => error.exit_code(),
            Self::Workflow(_) => WorkflowError::exit_code(),
        }
    }

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::Common(_) => CommonError::hint(),
            Self::RunSetup(error) => error.hint(),
            Self::AuthoringObserve(error) => error.hint(),
            Self::Workflow(_) => WorkflowError::hint(),
        }
    }

    #[must_use]
    pub fn with_details(self, details: impl Into<String>) -> CliError {
        CliError::new(self).with_details(details)
    }

    #[must_use]
    pub fn missing_tools(tools: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::missing_tools(tools))
    }

    #[must_use]
    pub fn unsafe_name(name: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::unsafe_name(name))
    }

    #[must_use]
    pub fn command_failed(command: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::command_failed(command))
    }

    #[must_use]
    pub fn missing_file(path: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::missing_file(path))
    }

    #[must_use]
    pub fn invalid_json(path: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::invalid_json(path))
    }

    #[must_use]
    pub fn path_not_found(dotted_path: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::path_not_found(dotted_path))
    }

    #[must_use]
    pub fn not_a_mapping(label: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::not_a_mapping(label))
    }

    #[must_use]
    pub fn not_string_keys(label: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::not_string_keys(label))
    }

    #[must_use]
    pub fn not_a_list(label: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::not_a_list(label))
    }

    #[must_use]
    pub fn not_all_strings(label: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::not_all_strings(label))
    }

    #[must_use]
    pub fn missing_fields(
        label: impl Into<Cow<'static, str>>,
        fields: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::Common(CommonError::missing_fields(label, fields))
    }

    #[must_use]
    pub fn field_type_mismatch(
        label: impl Into<Cow<'static, str>>,
        field: impl Into<Cow<'static, str>>,
        expected: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::Common(CommonError::field_type_mismatch(label, field, expected))
    }

    #[must_use]
    pub fn missing_sections(
        label: impl Into<Cow<'static, str>>,
        sections: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::Common(CommonError::missing_sections(label, sections))
    }

    #[must_use]
    pub fn io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::io(detail))
    }

    #[must_use]
    pub fn serialize(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::serialize(detail))
    }

    #[must_use]
    pub fn hook_payload_invalid(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::hook_payload_invalid(detail))
    }

    #[must_use]
    pub fn cluster_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::cluster_error(detail))
    }

    #[must_use]
    pub fn usage_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::usage_error(detail))
    }

    #[must_use]
    pub fn json_parse(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Common(CommonError::json_parse(detail))
    }

    #[must_use]
    pub fn missing_closeout_artifact(rel: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::missing_closeout_artifact(rel))
    }

    #[must_use]
    pub fn missing_run_context_value(field: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::missing_run_context_value(field))
    }

    #[must_use]
    pub fn missing_run_location(run_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::missing_run_location(run_id))
    }

    #[must_use]
    pub fn run_dir_exists(run_dir: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::run_dir_exists(run_dir))
    }

    #[must_use]
    pub fn run_group_already_recorded(group_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::run_group_already_recorded(group_id))
    }

    #[must_use]
    pub fn run_group_not_found(group_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::run_group_not_found(group_id))
    }

    #[must_use]
    pub fn gateway_download_empty(path: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::gateway_download_empty(path))
    }

    #[must_use]
    pub fn no_resource_kinds(manifest: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::no_resource_kinds(manifest))
    }

    #[must_use]
    pub fn route_not_found(route_match: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::route_not_found(route_match))
    }

    #[must_use]
    pub fn universal_validation_failed(manifest: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::universal_validation_failed(manifest))
    }

    #[must_use]
    pub fn kubectl_target_override_forbidden(flag: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::kubectl_target_override_forbidden(flag))
    }

    #[must_use]
    pub fn unknown_tracked_cluster(
        cluster: impl Into<Cow<'static, str>>,
        choices: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::RunSetup(RunSetupError::unknown_tracked_cluster(cluster, choices))
    }

    #[must_use]
    pub fn non_local_kubeconfig(path: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::non_local_kubeconfig(path))
    }

    #[must_use]
    pub fn envoy_config_type_not_found(type_name: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::envoy_config_type_not_found(type_name))
    }

    #[must_use]
    pub fn envoy_capture_args_required(fields: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::envoy_capture_args_required(fields))
    }

    #[must_use]
    pub fn report_line_limit(
        count: impl Into<Cow<'static, str>>,
        limit: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::RunSetup(RunSetupError::report_line_limit(count, limit))
    }

    #[must_use]
    pub fn report_code_block_limit(
        count: impl Into<Cow<'static, str>>,
        limit: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::RunSetup(RunSetupError::report_code_block_limit(count, limit))
    }

    #[must_use]
    pub fn evidence_label_not_found(label: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::evidence_label_not_found(label))
    }

    #[must_use]
    pub fn container_start_failed(name: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::container_start_failed(name))
    }

    #[must_use]
    pub fn container_not_found(name: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::container_not_found(name))
    }

    #[must_use]
    pub fn cp_api_unreachable(url: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::cp_api_unreachable(url))
    }

    #[must_use]
    pub fn token_generation_failed(details: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::token_generation_failed(details))
    }

    #[must_use]
    pub fn docker_network_failed(name: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::docker_network_failed(name))
    }

    #[must_use]
    pub fn compose_file_failed(path: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::compose_file_failed(path))
    }

    #[must_use]
    pub fn image_build_failed(target: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::image_build_failed(target))
    }

    #[must_use]
    pub fn template_render(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::template_render(detail))
    }

    #[must_use]
    pub fn service_readiness_timeout(name: impl Into<Cow<'static, str>>) -> Self {
        Self::RunSetup(RunSetupError::service_readiness_timeout(name))
    }

    #[must_use]
    pub fn authoring_payload_invalid(
        kind: impl Into<Cow<'static, str>>,
        details: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::authoring_payload_invalid(
            kind, details,
        ))
    }

    #[must_use]
    pub fn authoring_show_kind_missing(kind: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::authoring_show_kind_missing(kind))
    }

    #[must_use]
    pub fn amendments_required(path: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::amendments_required(path))
    }

    #[must_use]
    pub fn authoring_validate_failed(targets: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::authoring_validate_failed(targets))
    }

    #[must_use]
    pub fn authoring_suite_dir_exists(path: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::authoring_suite_dir_exists(path))
    }

    #[must_use]
    pub fn session_not_found(session_id: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::session_not_found(session_id))
    }

    #[must_use]
    pub fn session_parse_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::session_parse_error(detail))
    }

    #[must_use]
    pub fn session_ambiguous(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringObserve(AuthoringObserveError::session_ambiguous(detail))
    }

    #[must_use]
    pub fn invalid_transition(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::invalid_transition(detail))
    }

    #[must_use]
    pub fn workflow_io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_io(detail))
    }

    #[must_use]
    pub fn workflow_parse(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_parse(detail))
    }

    #[must_use]
    pub fn workflow_version(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_version(detail))
    }

    #[must_use]
    pub fn concurrent_modification(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::concurrent_modification(detail))
    }

    #[must_use]
    pub fn workflow_serialize(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Workflow(WorkflowError::workflow_serialize(detail))
    }
}
