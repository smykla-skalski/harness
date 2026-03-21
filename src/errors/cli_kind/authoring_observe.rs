use std::borrow::Cow;

use crate::errors::{AuthoringObserveError, CliErrorKind};

impl CliErrorKind {
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
}
