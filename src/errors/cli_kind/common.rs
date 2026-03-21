use std::borrow::Cow;

use crate::errors::{CliErrorKind, CommonError};

impl CliErrorKind {
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
}
