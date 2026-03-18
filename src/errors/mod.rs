use std::borrow::Cow;
use std::error::Error;
use std::fmt;
use std::io;

mod authoring_observe;
mod common;
mod hook_message;
mod run_setup;
mod workflow;

pub use hook_message::HookMessage;

use self::authoring_observe::AuthoringObserveError;
use self::common::CommonError;
use self::run_setup::RunSetupError;
use self::workflow::WorkflowError;

/// Build a `Cow<'static, str>` from a `format!`-style expression.
///
/// Produces `Cow::Owned(format!(...))` so the caller never needs a
/// trailing `.into()`.
macro_rules! cow {
    ($($arg:tt)*) => {
        ::std::borrow::Cow::Owned(format!($($arg)*))
    };
}

pub(crate) use cow;

macro_rules! define_domain_error_enum {
    (
        $name:ident {
            $(
                $variant:ident $({ $($field:ident : $type:ty),* $(,)? })?
                => {
                    code: $code:literal,
                    msg: $msg:literal
                    $(, exit: $exit:expr)?
                }
            ),* $(,)?
        }
    ) => {
        #[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
        #[non_exhaustive]
        pub enum $name {
            $(
                #[error($msg)]
                $variant $({ $($field: $type),* })?,
            )*
        }

        impl $name {
            #[must_use]
            pub fn code(&self) -> &'static str {
                match self {
                    $(Self::$variant { .. } => $code,)*
                }
            }

            #[must_use]
            pub fn exit_code(&self) -> i32 {
                match self {
                    $(Self::$variant { .. } => define_domain_error_enum!(@exit $($exit)?),)*
                }
            }
        }
    };

    (@exit) => { 5 };
    (@exit $exit:expr) => { $exit };
}

pub(crate) use define_domain_error_enum;

macro_rules! domain_constructor {
    ($fn_name:ident, $variant:ident, $($field:ident),+) => {
        pub fn $fn_name($($field: impl Into<Cow<'static, str>>),+) -> Self {
            Self::$variant { $($field: $field.into()),+ }
        }
    };
}

pub(crate) use domain_constructor;

/// Public wrapper around domain-specific CLI errors.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum CliErrorKind {
    #[error(transparent)]
    Common(CommonError),
    #[error(transparent)]
    RunSetup(RunSetupError),
    #[error(transparent)]
    AuthoringObserve(AuthoringObserveError),
    #[error(transparent)]
    Workflow(WorkflowError),
}

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
            Self::Workflow(error) => error.exit_code(),
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
        CliError {
            kind: self,
            details: Some(details.into()),
        }
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

/// The unified CLI error type, following the `io::Error` pattern.
///
/// Wraps a [`CliErrorKind`] with optional detail text.
#[derive(Debug)]
pub struct CliError {
    kind: CliErrorKind,
    details: Option<String>,
}

impl CliError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        self.kind.code()
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        self.kind.exit_code()
    }

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        self.kind.hint()
    }

    #[must_use]
    pub fn details(&self) -> Option<&str> {
        self.details.as_deref()
    }

    #[must_use]
    pub fn kind(&self) -> CliErrorKind {
        self.kind.clone()
    }

    #[must_use]
    pub fn message(&self) -> String {
        self.kind.to_string()
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code(), self.kind)
    }
}

impl Error for CliError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.kind)
    }
}

impl From<CliErrorKind> for CliError {
    fn from(kind: CliErrorKind) -> Self {
        Self {
            kind,
            details: None,
        }
    }
}

impl From<io::Error> for CliError {
    fn from(error: io::Error) -> Self {
        CliErrorKind::io(cow!("IO error: {error}")).into()
    }
}

/// Format a [`CliError`] for display to stderr.
#[must_use]
pub fn render_error(error: &CliError) -> String {
    use std::fmt::Write;

    let mut buf = format!("ERROR [{}] {}", error.code(), error.kind);
    if let Some(hint) = error.hint() {
        let _ = write!(buf, "\nHint: {hint}");
    }
    if let Some(details) = error.details() {
        let _ = write!(buf, "\nDetails:\n{details}");
    }
    buf
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;
    use crate::hook::Decision;

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
            CliErrorKind::AuthoringSessionMissing,
            CliErrorKind::AuthoringPayloadMissing,
            CliErrorKind::authoring_payload_invalid("", ""),
            CliErrorKind::authoring_show_kind_missing(""),
            CliErrorKind::authoring_validate_failed(""),
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
            CliErrorKind::authoring_suite_dir_exists(""),
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
        assert!(hint.contains("harness service down demo-svc"));
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
        assert!(result.message.contains("`harness run`"));
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
            HookMessage::SuiteAuthorTracked,
        ];
        assert_eq!(all_hooks.len(), 27);
    }
}
