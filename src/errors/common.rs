use std::borrow::Cow;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum CommonError {
    #[error("command args must not be empty")]
    EmptyCommandArgs,
    #[error("missing required tools: {tools}")]
    MissingTools { tools: Cow<'static, str> },
    #[error("unsafe name: {name} (must not contain path separators or \"..\")")]
    UnsafeName { name: Cow<'static, str> },
    #[error("command failed: {command}")]
    CommandFailed { command: Cow<'static, str> },
    #[error("missing file: {path}")]
    MissingFile { path: Cow<'static, str> },
    #[error("invalid JSON in {path}")]
    InvalidJson { path: Cow<'static, str> },
    #[error("path not found: {dotted_path}")]
    PathNotFound { dotted_path: Cow<'static, str> },
    #[error("{label} must be a mapping")]
    NotAMapping { label: Cow<'static, str> },
    #[error("{label} must use string keys")]
    NotStringKeys { label: Cow<'static, str> },
    #[error("{label} must be a list")]
    NotAList { label: Cow<'static, str> },
    #[error("{label} must contain only strings")]
    NotAllStrings { label: Cow<'static, str> },
    #[error("missing YAML frontmatter")]
    MissingFrontmatter,
    #[error("unterminated YAML frontmatter")]
    UnterminatedFrontmatter,
    #[error("missing required fields: {label}: {fields}")]
    MissingFields {
        label: Cow<'static, str>,
        fields: Cow<'static, str>,
    },
    #[error("field type mismatch in {label}: {field} (expected {expected})")]
    FieldTypeMismatch {
        label: Cow<'static, str>,
        field: Cow<'static, str>,
        expected: Cow<'static, str>,
    },
    #[error("missing sections: {label}: {sections}")]
    MissingSections {
        label: Cow<'static, str>,
        sections: Cow<'static, str>,
    },
    #[error("markdown row shape mismatch")]
    MarkdownShapeMismatch,
    #[error("{detail}")]
    Io { detail: Cow<'static, str> },
    #[error("serialization failed: {detail}")]
    Serialize { detail: Cow<'static, str> },
    #[error("{detail}")]
    HookPayloadInvalid { detail: Cow<'static, str> },
    #[error("{detail}")]
    ClusterError { detail: Cow<'static, str> },
    #[error("{detail}")]
    UsageError { detail: Cow<'static, str> },
    #[error("{detail}")]
    JsonParse { detail: Cow<'static, str> },
}

impl CommonError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyCommandArgs => "KSRCLI001",
            Self::MissingTools { .. } => "KSRCLI002",
            Self::UnsafeName { .. } => "KSRCLI059",
            Self::CommandFailed { .. } => "KSRCLI004",
            Self::MissingFile { .. } => "KSRCLI014",
            Self::InvalidJson { .. } => "KSRCLI019",
            Self::PathNotFound { .. } => "KSRCLI017",
            Self::NotAMapping { .. } => "KSRCLI010",
            Self::NotStringKeys { .. } => "KSRCLI011",
            Self::NotAList { .. } => "KSRCLI012",
            Self::NotAllStrings { .. } => "KSRCLI013",
            Self::MissingFrontmatter => "KSRCLI015",
            Self::UnterminatedFrontmatter => "KSRCLI016",
            Self::MissingFields { .. } => "KSRCLI020",
            Self::FieldTypeMismatch { .. } => "KSRCLI022",
            Self::MissingSections { .. } => "KSRCLI021",
            Self::MarkdownShapeMismatch => "KSRCLI999",
            Self::Io { .. } => "IO001",
            Self::Serialize { .. } => "IO002",
            Self::HookPayloadInvalid { .. } => "KSH001",
            Self::ClusterError { .. } => "CLUSTER",
            Self::UsageError { .. } => "USAGE",
            Self::JsonParse { .. } => "JSON",
        }
    }

    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::EmptyCommandArgs | Self::MissingTools { .. } | Self::UnsafeName { .. } => 3,
            Self::CommandFailed { .. } => 4,
            Self::MarkdownShapeMismatch => 6,
            Self::Io { .. }
            | Self::Serialize { .. }
            | Self::HookPayloadInvalid { .. }
            | Self::ClusterError { .. }
            | Self::UsageError { .. } => 1,
            Self::MissingFile { .. }
            | Self::InvalidJson { .. }
            | Self::PathNotFound { .. }
            | Self::NotAMapping { .. }
            | Self::NotStringKeys { .. }
            | Self::NotAList { .. }
            | Self::NotAllStrings { .. }
            | Self::MissingFrontmatter
            | Self::UnterminatedFrontmatter
            | Self::MissingFields { .. }
            | Self::FieldTypeMismatch { .. }
            | Self::MissingSections { .. }
            | Self::JsonParse { .. } => 5,
        }
    }

    #[must_use]
    pub fn missing_tools(tools: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingTools {
            tools: tools.into(),
        }
    }

    #[must_use]
    pub fn unsafe_name(name: impl Into<Cow<'static, str>>) -> Self {
        Self::UnsafeName { name: name.into() }
    }

    #[must_use]
    pub fn command_failed(command: impl Into<Cow<'static, str>>) -> Self {
        Self::CommandFailed {
            command: command.into(),
        }
    }

    #[must_use]
    pub fn missing_file(path: impl Into<Cow<'static, str>>) -> Self {
        Self::MissingFile { path: path.into() }
    }

    #[must_use]
    pub fn invalid_json(path: impl Into<Cow<'static, str>>) -> Self {
        Self::InvalidJson { path: path.into() }
    }

    #[must_use]
    pub fn path_not_found(dotted_path: impl Into<Cow<'static, str>>) -> Self {
        Self::PathNotFound {
            dotted_path: dotted_path.into(),
        }
    }

    #[must_use]
    pub fn not_a_mapping(label: impl Into<Cow<'static, str>>) -> Self {
        Self::NotAMapping {
            label: label.into(),
        }
    }

    #[must_use]
    pub fn not_string_keys(label: impl Into<Cow<'static, str>>) -> Self {
        Self::NotStringKeys {
            label: label.into(),
        }
    }

    #[must_use]
    pub fn not_a_list(label: impl Into<Cow<'static, str>>) -> Self {
        Self::NotAList {
            label: label.into(),
        }
    }

    #[must_use]
    pub fn not_all_strings(label: impl Into<Cow<'static, str>>) -> Self {
        Self::NotAllStrings {
            label: label.into(),
        }
    }

    #[must_use]
    pub fn missing_fields(
        label: impl Into<Cow<'static, str>>,
        fields: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::MissingFields {
            label: label.into(),
            fields: fields.into(),
        }
    }

    #[must_use]
    pub fn field_type_mismatch(
        label: impl Into<Cow<'static, str>>,
        field: impl Into<Cow<'static, str>>,
        expected: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::FieldTypeMismatch {
            label: label.into(),
            field: field.into(),
            expected: expected.into(),
        }
    }

    #[must_use]
    pub fn missing_sections(
        label: impl Into<Cow<'static, str>>,
        sections: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self::MissingSections {
            label: label.into(),
            sections: sections.into(),
        }
    }

    #[must_use]
    pub fn io(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Io {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn serialize(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::Serialize {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn hook_payload_invalid(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::HookPayloadInvalid {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn cluster_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::ClusterError {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn usage_error(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::UsageError {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn json_parse(detail: impl Into<Cow<'static, str>>) -> Self {
        Self::JsonParse {
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn hint() -> Option<String> {
        None
    }
}
