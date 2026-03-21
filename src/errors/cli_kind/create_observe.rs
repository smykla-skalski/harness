use std::borrow::Cow;

use crate::errors::{CliErrorKind, CreateObserveError};

impl CliErrorKind {
    #[must_use]
    pub fn create_payload_invalid(
        kind: impl Into<Cow<'static, str>>,
        details: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::CreateObserve(CreateObserveError::create_payload_invalid(kind, details))
    }

    #[must_use]
    pub fn create_show_kind_missing(kind: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::create_show_kind_missing(kind))
    }

    #[must_use]
    pub fn amendments_required(path: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::amendments_required(path))
    }

    #[must_use]
    pub fn create_validate_failed(targets: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::create_validate_failed(targets))
    }

    #[must_use]
    pub fn create_suite_dir_exists(path: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::create_suite_dir_exists(path))
    }

    #[must_use]
    pub fn session_not_found(session_id: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::session_not_found(session_id))
    }

    #[must_use]
    pub fn session_parse_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::session_parse_error(detail))
    }

    #[must_use]
    pub fn session_ambiguous(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::CreateObserve(CreateObserveError::session_ambiguous(detail))
    }
}
