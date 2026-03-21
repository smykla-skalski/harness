use std::borrow::Cow;

use super::RunSetupError;

impl RunSetupError {
    #[must_use]
    pub fn missing_closeout_artifact(rel: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingCloseoutArtifact { rel: rel.into() }
    }

    #[must_use]
    pub fn missing_run_context_value(field: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingRunContextValue {
            field: field.into(),
        }
    }

    #[must_use]
    pub fn missing_run_location(run_id: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingRunLocation {
            run_id: run_id.into(),
        }
    }

    #[must_use]
    pub fn run_dir_exists(run_dir: impl Into<Cow<'static, str>>) -> Self {
        Self::RunDirExists {
            run_dir: run_dir.into(),
        }
    }

    #[must_use]
    pub fn run_group_already_recorded(group_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunGroupAlreadyRecorded {
            group_id: group_id.into(),
        }
    }

    #[must_use]
    pub fn run_group_not_found(group_id: impl Into<Cow<'static, str>>) -> Self {
        Self::RunGroupNotFound {
            group_id: group_id.into(),
        }
    }

    #[must_use]
    pub fn gateway_download_empty(path: impl Into<Cow<'static, str>>) -> Self {
        Self::GatewayDownloadEmpty { path: path.into() }
    }

    #[must_use]
    pub fn no_resource_kinds(manifest: impl Into<Cow<'static, str>>) -> Self {
        Self::NoResourceKinds {
            manifest: manifest.into(),
        }
    }

    #[must_use]
    pub fn route_not_found(route_match: impl Into<Cow<'static, str>>) -> Self {
        Self::RouteNotFound {
            route_match: route_match.into(),
        }
    }

    #[must_use]
    pub fn universal_validation_failed(manifest: impl Into<Cow<'static, str>>) -> Self {
        Self::UniversalValidationFailed {
            manifest: manifest.into(),
        }
    }

    #[must_use]
    pub fn kubectl_target_override_forbidden(flag: impl Into<Cow<'static, str>>) -> Self {
        Self::KubectlTargetOverrideForbidden { flag: flag.into() }
    }

    #[must_use]
    pub fn unknown_tracked_cluster(
        cluster: impl Into<Cow<'static, str>>,
        choices: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::UnknownTrackedCluster {
            cluster: cluster.into(),
            choices: choices.into(),
        }
    }

    #[must_use]
    pub fn non_local_kubeconfig(path: impl Into<Cow<'static, str>>) -> Self {
        Self::NonLocalKubeconfig { path: path.into() }
    }

    #[must_use]
    pub fn envoy_config_type_not_found(type_name: impl Into<Cow<'static, str>>) -> Self {
        Self::EnvoyConfigTypeNotFound {
            type_name: type_name.into(),
        }
    }

    #[must_use]
    pub fn envoy_capture_args_required(fields: impl Into<Cow<'static, str>>) -> Self {
        Self::EnvoyCaptureArgsRequired {
            fields: fields.into(),
        }
    }

    #[must_use]
    pub fn report_line_limit(
        count: impl Into<Cow<'static, str>>,
        limit: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::ReportLineLimit {
            count: count.into(),
            limit: limit.into(),
        }
    }

    #[must_use]
    pub fn report_code_block_limit(
        count: impl Into<Cow<'static, str>>,
        limit: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::ReportCodeBlockLimit {
            count: count.into(),
            limit: limit.into(),
        }
    }

    #[must_use]
    pub fn evidence_label_not_found(label: impl Into<Cow<'static, str>>) -> Self {
        Self::EvidenceLabelNotFound {
            label: label.into(),
        }
    }

    #[must_use]
    pub fn container_start_failed(name: impl Into<Cow<'static, str>>) -> Self {
        Self::ContainerStartFailed { name: name.into() }
    }

    #[must_use]
    pub fn container_not_found(name: impl Into<Cow<'static, str>>) -> Self {
        Self::ContainerNotFound { name: name.into() }
    }

    #[must_use]
    pub fn cp_api_unreachable(url: impl Into<Cow<'static, str>>) -> Self {
        Self::CpApiUnreachable { url: url.into() }
    }

    #[must_use]
    pub fn token_generation_failed(details: impl Into<Cow<'static, str>>) -> Self {
        Self::TokenGenerationFailed {
            details: details.into(),
        }
    }

    #[must_use]
    pub fn docker_network_failed(name: impl Into<Cow<'static, str>>) -> Self {
        Self::DockerNetworkFailed { name: name.into() }
    }

    #[must_use]
    pub fn compose_file_failed(path: impl Into<Cow<'static, str>>) -> Self {
        Self::ComposeFileFailed { path: path.into() }
    }

    #[must_use]
    pub fn image_build_failed(target: impl Into<Cow<'static, str>>) -> Self {
        Self::ImageBuildFailed {
            target: target.into(),
        }
    }

    #[must_use]
    pub fn template_render(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::TemplateRender {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn service_readiness_timeout(name: impl Into<Cow<'static, str>>) -> Self {
        Self::ServiceReadinessTimeout { name: name.into() }
    }
}
