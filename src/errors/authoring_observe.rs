use std::borrow::Cow;

use super::{define_domain_error_enum, domain_constructor};

define_domain_error_enum! {
    AuthoringObserveError {
        AuthoringSessionMissing => {
            code: "KSRCLI040",
            msg: "missing active suite:new authoring session"
        },
        AuthoringPayloadMissing => {
            code: "KSRCLI041",
            msg: "missing suite:new payload input"
        },
        AuthoringPayloadInvalid { kind: Cow<'static, str>, details: Cow<'static, str> } => {
            code: "KSRCLI042",
            msg: "invalid suite:new {kind} payload: {details}"
        },
        AuthoringShowKindMissing { kind: Cow<'static, str> } => {
            code: "KSRCLI043",
            msg: "missing saved suite:new payload: {kind}"
        },
        AmendmentsRequired { path: Cow<'static, str> } => {
            code: "KSRCLI045",
            msg: "suite amendments entry is missing or empty: {path}"
        },
        AuthoringValidateFailed { targets: Cow<'static, str> } => {
            code: "KSRCLI046",
            msg: "suite:new manifest validation failed: {targets}"
        },
        KubectlValidateDecisionRequired => {
            code: "KSRCLI047",
            msg: "suite:new local validator decision is still required"
        },
        KubectlValidateUnavailable => {
            code: "KSRCLI048",
            msg: "suite:new local validator is unavailable"
        },
        AuthoringSuiteDirExists { path: Cow<'static, str> } => {
            code: "KSRCLI062",
            msg: "suite directory already exists at {path}"
        },
        SessionNotFound { session_id: Cow<'static, str> } => {
            code: "KSRCLI080",
            msg: "session not found: {session_id}",
            exit: 1
        },
        SessionParseError { detail: Cow<'static, str> } => {
            code: "KSRCLI081",
            msg: "session parse error: {detail}",
            exit: 1
        },
        SessionAmbiguous { detail: Cow<'static, str> } => {
            code: "KSRCLI085",
            msg: "ambiguous session: {detail}",
            exit: 1
        }
    }
}

impl AuthoringObserveError {
    domain_constructor!(
        authoring_payload_invalid,
        AuthoringPayloadInvalid,
        kind,
        details
    );
    domain_constructor!(authoring_show_kind_missing, AuthoringShowKindMissing, kind);
    domain_constructor!(amendments_required, AmendmentsRequired, path);
    domain_constructor!(authoring_validate_failed, AuthoringValidateFailed, targets);
    domain_constructor!(authoring_suite_dir_exists, AuthoringSuiteDirExists, path);
    domain_constructor!(session_not_found, SessionNotFound, session_id);
    domain_constructor!(session_parse_error, SessionParseError, detail);
    domain_constructor!(session_ambiguous, SessionAmbiguous, detail);

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
            Self::SessionAmbiguous { .. } => {
                Some("Use --project-hint to narrow the search.".into())
            }
            _ => None,
        }
    }
}
