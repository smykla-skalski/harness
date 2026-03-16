use std::borrow::Cow;

use super::{define_domain_error_enum, domain_constructor};

define_domain_error_enum! {
    CommonError {
        EmptyCommandArgs => {
            code: "KSRCLI001",
            msg: "command args must not be empty",
            exit: 3
        },
        MissingTools { tools: Cow<'static, str> } => {
            code: "KSRCLI002",
            msg: "missing required tools: {tools}",
            exit: 3
        },
        UnsafeName { name: Cow<'static, str> } => {
            code: "KSRCLI059",
            msg: "unsafe name: {name} (must not contain path separators or \"..\")",
            exit: 3
        },
        CommandFailed { command: Cow<'static, str> } => {
            code: "KSRCLI004",
            msg: "command failed: {command}",
            exit: 4
        },
        MissingFile { path: Cow<'static, str> } => {
            code: "KSRCLI014",
            msg: "missing file: {path}"
        },
        InvalidJson { path: Cow<'static, str> } => {
            code: "KSRCLI019",
            msg: "invalid JSON in {path}"
        },
        PathNotFound { dotted_path: Cow<'static, str> } => {
            code: "KSRCLI017",
            msg: "path not found: {dotted_path}"
        },
        NotAMapping { label: Cow<'static, str> } => {
            code: "KSRCLI010",
            msg: "{label} must be a mapping"
        },
        NotStringKeys { label: Cow<'static, str> } => {
            code: "KSRCLI011",
            msg: "{label} must use string keys"
        },
        NotAList { label: Cow<'static, str> } => {
            code: "KSRCLI012",
            msg: "{label} must be a list"
        },
        NotAllStrings { label: Cow<'static, str> } => {
            code: "KSRCLI013",
            msg: "{label} must contain only strings"
        },
        MissingFrontmatter => {
            code: "KSRCLI015",
            msg: "missing YAML frontmatter"
        },
        UnterminatedFrontmatter => {
            code: "KSRCLI016",
            msg: "unterminated YAML frontmatter"
        },
        MissingFields { label: Cow<'static, str>, fields: Cow<'static, str> } => {
            code: "KSRCLI020",
            msg: "missing required fields: {label}: {fields}"
        },
        FieldTypeMismatch {
            label: Cow<'static, str>,
            field: Cow<'static, str>,
            expected: Cow<'static, str>,
        } => {
            code: "KSRCLI022",
            msg: "field type mismatch in {label}: {field} (expected {expected})"
        },
        MissingSections { label: Cow<'static, str>, sections: Cow<'static, str> } => {
            code: "KSRCLI021",
            msg: "missing sections: {label}: {sections}"
        },
        MarkdownShapeMismatch => {
            code: "KSRCLI999",
            msg: "markdown row shape mismatch",
            exit: 6
        },
        Io { detail: Cow<'static, str> } => {
            code: "IO001",
            msg: "{detail}",
            exit: 1
        },
        Serialize { detail: Cow<'static, str> } => {
            code: "IO002",
            msg: "serialization failed: {detail}",
            exit: 1
        },
        HookPayloadInvalid { detail: Cow<'static, str> } => {
            code: "KSH001",
            msg: "{detail}",
            exit: 1
        },
        ClusterError { detail: Cow<'static, str> } => {
            code: "CLUSTER",
            msg: "{detail}",
            exit: 1
        },
        UsageError { detail: Cow<'static, str> } => {
            code: "USAGE",
            msg: "{detail}",
            exit: 1
        },
        JsonParse { detail: Cow<'static, str> } => {
            code: "JSON",
            msg: "{detail}"
        }
    }
}

impl CommonError {
    domain_constructor!(missing_tools, MissingTools, tools);
    domain_constructor!(unsafe_name, UnsafeName, name);
    domain_constructor!(command_failed, CommandFailed, command);
    domain_constructor!(missing_file, MissingFile, path);
    domain_constructor!(invalid_json, InvalidJson, path);
    domain_constructor!(path_not_found, PathNotFound, dotted_path);
    domain_constructor!(not_a_mapping, NotAMapping, label);
    domain_constructor!(not_string_keys, NotStringKeys, label);
    domain_constructor!(not_a_list, NotAList, label);
    domain_constructor!(not_all_strings, NotAllStrings, label);
    domain_constructor!(missing_fields, MissingFields, label, fields);
    domain_constructor!(
        field_type_mismatch,
        FieldTypeMismatch,
        label,
        field,
        expected
    );
    domain_constructor!(missing_sections, MissingSections, label, sections);
    domain_constructor!(io, Io, detail);
    domain_constructor!(serialize, Serialize, detail);
    domain_constructor!(hook_payload_invalid, HookPayloadInvalid, detail);
    domain_constructor!(cluster_error, ClusterError, detail);
    domain_constructor!(usage_error, UsageError, detail);
    domain_constructor!(json_parse, JsonParse, detail);

    #[must_use]
    pub fn hint() -> Option<String> {
        None
    }
}
