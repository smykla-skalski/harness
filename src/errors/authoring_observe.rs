use std::borrow::Cow;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum AuthoringObserveError {
    #[error("missing active suite:new authoring session")]
    AuthoringSessionMissing,
    #[error("missing suite:new payload input")]
    AuthoringPayloadMissing,
    #[error("invalid suite:new {kind} payload: {details}")]
    AuthoringPayloadInvalid {
        kind: Cow<'static, str>,
        details: Cow<'static, str>,
    },
    #[error("missing saved suite:new payload: {kind}")]
    AuthoringShowKindMissing { kind: Cow<'static, str> },
    #[error("suite amendments entry is missing or empty: {path}")]
    AmendmentsRequired { path: Cow<'static, str> },
    #[error("suite:new manifest validation failed: {targets}")]
    AuthoringValidateFailed { targets: Cow<'static, str> },
    #[error("suite:new local validator decision is still required")]
    KubectlValidateDecisionRequired,
    #[error("suite:new local validator is unavailable")]
    KubectlValidateUnavailable,
    #[error("suite directory already exists at {path}")]
    AuthoringSuiteDirExists { path: Cow<'static, str> },
    #[error("session not found: {session_id}")]
    SessionNotFound { session_id: Cow<'static, str> },
    #[error("session parse error: {detail}")]
    SessionParseError { detail: Cow<'static, str> },
    #[error("ambiguous session: {detail}")]
    SessionAmbiguous { detail: Cow<'static, str> },
}

impl AuthoringObserveError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::AuthoringSessionMissing => "KSRCLI040",
            Self::AuthoringPayloadMissing => "KSRCLI041",
            Self::AuthoringPayloadInvalid { .. } => "KSRCLI042",
            Self::AuthoringShowKindMissing { .. } => "KSRCLI043",
            Self::AmendmentsRequired { .. } => "KSRCLI045",
            Self::AuthoringValidateFailed { .. } => "KSRCLI046",
            Self::KubectlValidateDecisionRequired => "KSRCLI047",
            Self::KubectlValidateUnavailable => "KSRCLI048",
            Self::AuthoringSuiteDirExists { .. } => "KSRCLI062",
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
            Self::AuthoringSessionMissing
            | Self::AuthoringPayloadMissing
            | Self::AuthoringPayloadInvalid { .. }
            | Self::AuthoringShowKindMissing { .. }
            | Self::AmendmentsRequired { .. }
            | Self::AuthoringValidateFailed { .. }
            | Self::KubectlValidateDecisionRequired
            | Self::KubectlValidateUnavailable
            | Self::AuthoringSuiteDirExists { .. } => 5,
        }
    }

    #[must_use]
    pub fn authoring_payload_invalid(
        kind: impl Into<Cow<'static, str>>,
        details: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::AuthoringPayloadInvalid {
            kind: kind.into(),
            details: details.into(),
        }
    }

    #[must_use]
    pub fn authoring_show_kind_missing(kind: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringShowKindMissing { kind: kind.into() }
    }

    #[must_use]
    pub fn amendments_required(path: impl Into<Cow<'static, str>>) -> Self {
        Self::AmendmentsRequired { path: path.into() }
    }

    #[must_use]
    pub fn authoring_validate_failed(targets: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringValidateFailed {
            targets: targets.into(),
        }
    }

    #[must_use]
    pub fn authoring_suite_dir_exists(path: impl Into<Cow<'static, str>>) -> Self {
        Self::AuthoringSuiteDirExists { path: path.into() }
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
            Self::AuthoringSessionMissing => Some(
                "Run `harness authoring begin --skill suite:new --repo-root <path> --feature <name> --mode <interactive|bypass> --suite-dir <path> --suite-name <name>` first."
                    .into(),
            ),
            Self::AuthoringPayloadMissing => Some(
                "Prefer `--payload <json>` for regular saves. Use `--input <path>` for file-backed payloads. Pipe JSON to stdin only as a last-resort fallback when a regular `--payload` argument is not practical."
                    .into(),
            ),
            Self::AuthoringSuiteDirExists { .. } => Some(
                "Archive the existing suite (rename or move it) or use a different --suite-name."
                    .into(),
            ),
            Self::SessionNotFound { .. } => Some(
                "Check the session ID and ensure ~/.claude/projects/ contains the session file."
                    .into(),
            ),
            Self::SessionAmbiguous { .. } => Some("Use --project-hint to narrow the search.".into()),
            Self::AuthoringPayloadInvalid { .. }
            | Self::AuthoringShowKindMissing { .. }
            | Self::AmendmentsRequired { .. }
            | Self::AuthoringValidateFailed { .. }
            | Self::KubectlValidateDecisionRequired
            | Self::KubectlValidateUnavailable
            | Self::SessionParseError { .. } => None,
        }
    }
}
