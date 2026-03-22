use std::borrow::Cow;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum CreateObserveError {
    #[error("missing active suite:create session")]
    CreateSessionMissing,
    #[error("missing suite:create payload input")]
    CreatePayloadMissing,
    #[error("invalid suite:create {kind} payload: {details}")]
    CreatePayloadInvalid {
        kind: Cow<'static, str>,
        details: Cow<'static, str>,
    },
    #[error("missing saved suite:create payload: {kind}")]
    CreateShowKindMissing { kind: Cow<'static, str> },
    #[error("suite amendments entry is missing or empty: {path}")]
    AmendmentsRequired { path: Cow<'static, str> },
    #[error("suite:create manifest validation failed: {targets}")]
    CreateValidateFailed { targets: Cow<'static, str> },
    #[error("suite:create local validator decision is still required")]
    KubectlValidateDecisionRequired,
    #[error("suite:create local validator is unavailable")]
    KubectlValidateUnavailable,
    #[error("suite directory already exists at {path}")]
    CreateSuiteDirExists { path: Cow<'static, str> },
    #[error("session not found: {session_id}")]
    SessionNotFound { session_id: Cow<'static, str> },
    #[error("session parse error: {detail}")]
    SessionParseError { detail: Cow<'static, str> },
    #[error("ambiguous session: {detail}")]
    SessionAmbiguous { detail: Cow<'static, str> },
}

impl CreateObserveError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::CreateSessionMissing => "KSRCLI040",
            Self::CreatePayloadMissing => "KSRCLI041",
            Self::CreatePayloadInvalid { .. } => "KSRCLI042",
            Self::CreateShowKindMissing { .. } => "KSRCLI043",
            Self::AmendmentsRequired { .. } => "KSRCLI045",
            Self::CreateValidateFailed { .. } => "KSRCLI046",
            Self::KubectlValidateDecisionRequired => "KSRCLI047",
            Self::KubectlValidateUnavailable => "KSRCLI048",
            Self::CreateSuiteDirExists { .. } => "KSRCLI062",
            Self::SessionNotFound { .. } => "KSRCLI080",
            Self::SessionParseError { .. } => "KSRCLI081",
            Self::SessionAmbiguous { .. } => "KSRCLI085",
        }
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::SessionNotFound { .. }
            | Self::SessionParseError { .. }
            | Self::SessionAmbiguous { .. } => 1,
            Self::CreateSessionMissing
            | Self::CreatePayloadMissing
            | Self::CreatePayloadInvalid { .. }
            | Self::CreateShowKindMissing { .. }
            | Self::AmendmentsRequired { .. }
            | Self::CreateValidateFailed { .. }
            | Self::KubectlValidateDecisionRequired
            | Self::KubectlValidateUnavailable
            | Self::CreateSuiteDirExists { .. } => 5,
        }
    }

    #[must_use]
    pub fn create_payload_invalid(
        kind: impl Into<Cow<'static, str>>,
        details: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::CreatePayloadInvalid {
            kind: kind.into(),
            details: details.into(),
        }
    }

    #[must_use]
    pub fn create_show_kind_missing(kind: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateShowKindMissing { kind: kind.into() }
    }

    #[must_use]
    pub fn amendments_required(path: impl Into<Cow<'static, str>>) -> Self {
        Self::AmendmentsRequired { path: path.into() }
    }

    #[must_use]
    pub fn create_validate_failed(targets: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateValidateFailed {
            targets: targets.into(),
        }
    }

    #[must_use]
    pub fn create_suite_dir_exists(path: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateSuiteDirExists { path: path.into() }
    }

    #[must_use]
    pub fn session_not_found(session_id: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionNotFound {
            session_id: session_id.into(),
        }
    }

    #[must_use]
    pub fn session_parse_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionParseError {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn session_ambiguous(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::SessionAmbiguous {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::CreateSessionMissing => Some(
                "Run `harness create begin --repo-root <path> --feature <name> --mode <interactive|bypass> --suite-dir <path> --suite-name <name>` first."
                    .into(),
            ),
            Self::CreatePayloadMissing => Some(
                "Prefer `--payload <json>` for regular saves. Use `--input <path>` for file-backed payloads. Pipe JSON to stdin only as a last-resort fallback when a regular `--payload` argument is not practical."
                    .into(),
            ),
            Self::CreateSuiteDirExists { .. } => Some(
                "Archive the existing suite (rename or move it) or use a different --suite-name."
                    .into(),
            ),
            Self::SessionNotFound { .. } => Some(
                "Check the session ID and ensure ~/.claude/projects/ contains the session file."
                    .into(),
            ),
            Self::SessionAmbiguous { .. } => Some("Use --project-hint to narrow the search.".into()),
            Self::CreatePayloadInvalid { .. }
            | Self::CreateShowKindMissing { .. }
            | Self::AmendmentsRequired { .. }
            | Self::CreateValidateFailed { .. }
            | Self::KubectlValidateDecisionRequired
            | Self::KubectlValidateUnavailable
            | Self::SessionParseError { .. } => None,
        }
    }
}
