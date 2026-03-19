use std::path::{Path, PathBuf};

use serde_json::Value;

/// Normalized tool categories shared across hook transports and session logs.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ToolCategory {
    Shell,
    FileRead,
    FileWrite,
    FileEdit,
    FileSearch,
    Agent,
    WebFetch,
    WebSearch,
    Custom(String),
}

/// Agent-agnostic representation of tool input.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum ToolInput {
    Shell {
        command: String,
        description: Option<String>,
    },
    FileRead {
        paths: Vec<PathBuf>,
    },
    FileWrite {
        paths: Vec<PathBuf>,
        content: Option<String>,
    },
    FileEdit {
        path: PathBuf,
        old_text: String,
        new_text: String,
    },
    FileSearch {
        pattern: String,
        path: Option<PathBuf>,
    },
    Other(Value),
}

impl ToolInput {
    #[must_use]
    pub fn command_text(&self) -> Option<&str> {
        match self {
            Self::Shell { command, .. } => Some(command.as_str()),
            _ => None,
        }
    }

    #[must_use]
    pub fn write_paths(&self) -> Vec<&Path> {
        match self {
            Self::FileRead { paths } | Self::FileWrite { paths, .. } => {
                paths.iter().map(PathBuf::as_path).collect()
            }
            Self::FileEdit { path, .. } => vec![path.as_path()],
            Self::Shell { .. } | Self::FileSearch { .. } | Self::Other(_) => Vec::new(),
        }
    }
}

/// Tool metadata extracted from either hook transports or transcript logs.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolContext {
    pub category: ToolCategory,
    pub original_name: String,
    pub input: ToolInput,
    pub input_raw: Value,
    pub response: Option<Value>,
}

impl ToolContext {
    #[must_use]
    pub fn new(
        original_name: impl Into<String>,
        category: ToolCategory,
        input_raw: Value,
        response: Option<Value>,
    ) -> Self {
        let original_name = original_name.into();
        let input = normalize_tool_input(&category, &input_raw);
        Self {
            category,
            original_name,
            input,
            input_raw,
            response,
        }
    }
}

#[must_use]
pub fn legacy_tool_category(name: &str) -> ToolCategory {
    match name {
        "Bash" => ToolCategory::Shell,
        "Read" => ToolCategory::FileRead,
        "Write" => ToolCategory::FileWrite,
        "Edit" => ToolCategory::FileEdit,
        "Glob" | "Grep" => ToolCategory::FileSearch,
        "Agent" => ToolCategory::Agent,
        "WebFetch" => ToolCategory::WebFetch,
        "WebSearch" => ToolCategory::WebSearch,
        other => ToolCategory::Custom(other.to_string()),
    }
}

#[must_use]
pub fn legacy_tool_context(name: &str, input_raw: Value, response: Option<Value>) -> ToolContext {
    ToolContext::new(name, legacy_tool_category(name), input_raw, response)
}

#[must_use]
pub fn normalize_tool_input(category: &ToolCategory, input: &Value) -> ToolInput {
    match category {
        ToolCategory::Shell => ToolInput::Shell {
            command: input
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            description: input
                .get("description")
                .and_then(Value::as_str)
                .map(ToString::to_string),
        },
        ToolCategory::FileRead => ToolInput::FileRead {
            paths: read_tool_paths(input),
        },
        ToolCategory::FileWrite => ToolInput::FileWrite {
            paths: read_tool_paths(input),
            content: input
                .get("content")
                .and_then(Value::as_str)
                .map(ToString::to_string),
        },
        ToolCategory::FileEdit => ToolInput::FileEdit {
            path: read_primary_path(input),
            old_text: input
                .get("old_text")
                .or_else(|| input.get("oldText"))
                .or_else(|| input.get("old_string"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            new_text: input
                .get("new_text")
                .or_else(|| input.get("newText"))
                .or_else(|| input.get("new_string"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        },
        ToolCategory::FileSearch => ToolInput::FileSearch {
            pattern: input
                .get("pattern")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            path: input
                .get("path")
                .or_else(|| input.get("file_path"))
                .and_then(Value::as_str)
                .map(PathBuf::from),
        },
        ToolCategory::Agent
        | ToolCategory::WebFetch
        | ToolCategory::WebSearch
        | ToolCategory::Custom(_) => ToolInput::Other(input.clone()),
    }
}

fn read_primary_path(input: &Value) -> PathBuf {
    input
        .get("file_path")
        .or_else(|| input.get("path"))
        .and_then(Value::as_str)
        .map_or_else(PathBuf::new, PathBuf::from)
}

fn read_tool_paths(input: &Value) -> Vec<PathBuf> {
    let mut paths = Vec::new();

    if let Some(path) = input
        .get("file_path")
        .or_else(|| input.get("path"))
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
    {
        paths.push(PathBuf::from(path));
    }

    if let Some(extra_paths) = input.get("file_paths").and_then(Value::as_array) {
        paths.extend(
            extra_paths
                .iter()
                .filter_map(Value::as_str)
                .filter(|path| !path.is_empty())
                .map(PathBuf::from),
        );
    }

    paths
}
