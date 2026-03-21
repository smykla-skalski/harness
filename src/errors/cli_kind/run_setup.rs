use std::borrow::Cow;

use crate::errors::{CliErrorKind, RunSetupError};

impl CliErrorKind {
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
}
