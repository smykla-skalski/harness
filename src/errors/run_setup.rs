use std::borrow::Cow;

use super::{define_domain_error_enum, domain_constructor};

define_domain_error_enum! {
    RunSetupError {
        MissingRunPointer => {
            code: "KSRCLI005",
            msg: "missing current run pointer"
        },
        MissingCloseoutArtifact { rel: Cow<'static, str> } => {
            code: "KSRCLI006",
            msg: "missing required closeout artifact: {rel}"
        },
        MissingStateCapture => {
            code: "KSRCLI007",
            msg: "run is missing a final state capture"
        },
        VerdictPending => {
            code: "KSRCLI008",
            msg: "run overall verdict is still pending"
        },
        MissingRunContextValue { field: Cow<'static, str> } => {
            code: "KSRCLI009",
            msg: "missing run context value: {field}"
        },
        MissingRunLocation { run_id: Cow<'static, str> } => {
            code: "KSRCLI018",
            msg: "missing explicit run location for run id: {run_id}"
        },
        RunDirExists { run_dir: Cow<'static, str> } => {
            code: "KSRCLI044",
            msg: "run directory already exists: {run_dir}"
        },
        MissingRunStatus => {
            code: "KSRCLI060",
            msg: "run has no recorded status"
        },
        RunGroupAlreadyRecorded { group_id: Cow<'static, str> } => {
            code: "KSRCLI053",
            msg: "run group is already recorded: {group_id}"
        },
        RunGroupNotFound { group_id: Cow<'static, str> } => {
            code: "KSRCLI054",
            msg: "group is not present in the run plan: {group_id}"
        },
        GatewayVersionMissing => {
            code: "KSRCLI032",
            msg: "unable to resolve Gateway API version from go.mod"
        },
        GatewayCrdsMissing => {
            code: "KSRCLI033",
            msg: "Gateway API CRDs are not installed",
            exit: 1
        },
        GatewayDownloadEmpty { path: Cow<'static, str> } => {
            code: "KSRCLI061",
            msg: "downloaded Gateway API manifest is empty: {path}"
        },
        NoResourceKinds { manifest: Cow<'static, str> } => {
            code: "KSRCLI030",
            msg: "no resource kinds found in {manifest}"
        },
        RouteNotFound { route_match: Cow<'static, str> } => {
            code: "KSRCLI031",
            msg: "route {route_match} not found"
        },
        UniversalValidationFailed { manifest: Cow<'static, str> } => {
            code: "KSRCLI083",
            msg: "universal manifest validation failed: {manifest}"
        },
        KumactlNotFound => {
            code: "KSRCLI034",
            msg: "unable to find local kumactl"
        },
        TrackedKubectlRequired => {
            code: "KSRCLI049",
            msg: "tracked kubectl command requires an active local cluster kubeconfig"
        },
        KubectlTargetOverrideForbidden { flag: Cow<'static, str> } => {
            code: "KSRCLI050",
            msg: "kubectl target override is not allowed in tracked runs: {flag}"
        },
        UnknownTrackedCluster { cluster: Cow<'static, str>, choices: Cow<'static, str> } => {
            code: "KSRCLI051",
            msg: "unknown tracked cluster member: {cluster}"
        },
        NonLocalKubeconfig { path: Cow<'static, str> } => {
            code: "KSRCLI052",
            msg: "tracked kubeconfig is not a local harness cluster: {path}"
        },
        EnvoyConfigTypeNotFound { type_name: Cow<'static, str> } => {
            code: "KSRCLI055",
            msg: "envoy config type not found: {type_name}"
        },
        EnvoyCaptureArgsRequired { fields: Cow<'static, str> } => {
            code: "KSRCLI056",
            msg: "envoy live capture requires: {fields}"
        },
        ReportLineLimit { count: Cow<'static, str>, limit: Cow<'static, str> } => {
            code: "KSRCLI035",
            msg: "report exceeds line limit: {count}>{limit}",
            exit: 1
        },
        ReportCodeBlockLimit { count: Cow<'static, str>, limit: Cow<'static, str> } => {
            code: "KSRCLI036",
            msg: "report exceeds code block limit: {count}>{limit}",
            exit: 1
        },
        EvidenceLabelNotFound { label: Cow<'static, str> } => {
            code: "KSRCLI057",
            msg: "no recorded artifact found for evidence label: {label}"
        },
        ReportGroupEvidenceRequired => {
            code: "KSRCLI058",
            msg: "group report requires at least one evidence input"
        },
        ContainerStartFailed { name: Cow<'static, str> } => {
            code: "KSRCLI070",
            msg: "container start failed: {name}",
            exit: 4
        },
        ContainerNotFound { name: Cow<'static, str> } => {
            code: "KSRCLI071",
            msg: "container not found: {name}",
            exit: 4
        },
        CpApiUnreachable { url: Cow<'static, str> } => {
            code: "KSRCLI072",
            msg: "control plane API unreachable: {url}",
            exit: 4
        },
        TokenGenerationFailed { details: Cow<'static, str> } => {
            code: "KSRCLI073",
            msg: "dataplane token generation failed: {details}",
            exit: 4
        },
        DockerNetworkFailed { name: Cow<'static, str> } => {
            code: "KSRCLI074",
            msg: "docker network operation failed: {name}",
            exit: 4
        },
        ComposeFileFailed { path: Cow<'static, str> } => {
            code: "KSRCLI075",
            msg: "docker compose operation failed: {path}",
            exit: 4
        },
        ImageBuildFailed { target: Cow<'static, str> } => {
            code: "KSRCLI076",
            msg: "image build failed: {target}",
            exit: 4
        },
        TemplateRender { detail: Cow<'static, str> } => {
            code: "KSRCLI077",
            msg: "template render failed: {detail}",
            exit: 4
        },
        ServiceReadinessTimeout { name: Cow<'static, str> } => {
            code: "KSRCLI078",
            msg: "service readiness timeout: {name}",
            exit: 4
        }
    }
}

impl RunSetupError {
    domain_constructor!(missing_closeout_artifact, MissingCloseoutArtifact, rel);
    domain_constructor!(missing_run_context_value, MissingRunContextValue, field);
    domain_constructor!(missing_run_location, MissingRunLocation, run_id);
    domain_constructor!(run_dir_exists, RunDirExists, run_dir);
    domain_constructor!(
        run_group_already_recorded,
        RunGroupAlreadyRecorded,
        group_id
    );
    domain_constructor!(run_group_not_found, RunGroupNotFound, group_id);
    domain_constructor!(gateway_download_empty, GatewayDownloadEmpty, path);
    domain_constructor!(no_resource_kinds, NoResourceKinds, manifest);
    domain_constructor!(route_not_found, RouteNotFound, route_match);
    domain_constructor!(
        universal_validation_failed,
        UniversalValidationFailed,
        manifest
    );
    domain_constructor!(
        kubectl_target_override_forbidden,
        KubectlTargetOverrideForbidden,
        flag
    );
    domain_constructor!(
        unknown_tracked_cluster,
        UnknownTrackedCluster,
        cluster,
        choices
    );
    domain_constructor!(non_local_kubeconfig, NonLocalKubeconfig, path);
    domain_constructor!(
        envoy_config_type_not_found,
        EnvoyConfigTypeNotFound,
        type_name
    );
    domain_constructor!(
        envoy_capture_args_required,
        EnvoyCaptureArgsRequired,
        fields
    );
    domain_constructor!(report_line_limit, ReportLineLimit, count, limit);
    domain_constructor!(report_code_block_limit, ReportCodeBlockLimit, count, limit);
    domain_constructor!(evidence_label_not_found, EvidenceLabelNotFound, label);
    domain_constructor!(container_start_failed, ContainerStartFailed, name);
    domain_constructor!(container_not_found, ContainerNotFound, name);
    domain_constructor!(cp_api_unreachable, CpApiUnreachable, url);
    domain_constructor!(token_generation_failed, TokenGenerationFailed, details);
    domain_constructor!(docker_network_failed, DockerNetworkFailed, name);
    domain_constructor!(compose_file_failed, ComposeFileFailed, path);
    domain_constructor!(image_build_failed, ImageBuildFailed, target);
    domain_constructor!(template_render, TemplateRender, detail);
    domain_constructor!(service_readiness_timeout, ServiceReadinessTimeout, name);

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::MissingRunPointer => Some("Run init first.".into()),
            Self::MissingRunContextValue { .. } => {
                Some("Run `harness run init` and the required setup step first.".into())
            }
            Self::MissingRunLocation { .. } => {
                Some("Pass `--run-root` or `--run-dir`, or run `harness run init` first.".into())
            }
            Self::GatewayDownloadEmpty { .. } => {
                Some("Check the URL and network connectivity.".into())
            }
            Self::KumactlNotFound => Some("Build kumactl first.".into()),
            Self::TrackedKubectlRequired => {
                Some("Run `harness run init` and `harness setup kuma cluster ...` first.".into())
            }
            Self::KubectlTargetOverrideForbidden { .. } => Some(
                "Use `harness run record --cluster <name> -- kubectl ...` for another tracked member.".into(),
            ),
            Self::UnknownTrackedCluster { choices, .. } => Some(format!("Use one of: {choices}.")),
            Self::NonLocalKubeconfig { .. } => Some(
                "Recreate the local cluster with `harness setup kuma cluster ...` before continuing.".into(),
            ),
            Self::EvidenceLabelNotFound { .. } => Some(
                "Use `harness run record --label <label>` or inspect `commands/command-log.md`."
                    .into(),
            ),
            Self::ReportGroupEvidenceRequired => {
                Some("Pass `--evidence-label <label>` or `--evidence <path>`.".into())
            }
            Self::RunDirExists { .. } => Some(
                "Use a new run id or resume the existing run instead of re-running `harness run init`."
                    .into(),
            ),
            Self::MissingRunStatus => Some(
                "The run-status.json file could not be loaded. Re-run `harness run init` or check the run directory."
                    .into(),
            ),
            Self::ServiceReadinessTimeout { name } => Some(format!(
                "Run `harness run kuma service down {name}` to clean up the container."
            )),
            _ => None,
        }
    }
}
