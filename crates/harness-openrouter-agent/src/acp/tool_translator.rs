//! Tool catalog + delta accumulator for the OpenRouter ACP shim.
//!
//! The catalog mirrors the in-daemon OpenRouter manager's surface (file IO +
//! terminal lifecycle) so prompts and tool semantics stay byte-identical across
//! the migration. The streaming delta accumulator keys partial tool-calls by
//! the OpenAI `index` so concatenation across SSE chunks remains
//! deterministic.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::openrouter::{
    AssistantToolCall, AssistantToolCallFunction, AssistantToolCallKind, ToolCallDelta,
    ToolDefinition, ToolDefinitionFunction, ToolDefinitionKind,
};

pub const TOOL_READ_TEXT_FILE: &str = "read_text_file";
pub const TOOL_WRITE_TEXT_FILE: &str = "write_text_file";
pub const TOOL_CREATE_TERMINAL: &str = "create_terminal";
pub const TOOL_TERMINAL_OUTPUT: &str = "terminal_output";
pub const TOOL_WAIT_FOR_TERMINAL_EXIT: &str = "wait_for_terminal_exit";
pub const TOOL_KILL_TERMINAL: &str = "kill_terminal";
pub const TOOL_RELEASE_TERMINAL: &str = "release_terminal";

/// Fixed catalog handed to the model on every turn.
#[must_use]
pub fn tool_catalog() -> Vec<ToolDefinition> {
    vec![
        read_text_file_definition(),
        write_text_file_definition(),
        create_terminal_definition(),
        terminal_output_definition(),
        wait_for_terminal_exit_definition(),
        kill_terminal_definition(),
        release_terminal_definition(),
    ]
}

/// Partial tool call assembled from streaming deltas, keyed by the OpenAI
/// `index` in `ChatChoiceDelta::tool_calls`. The `id` and `name` arrive in
/// the first delta for a given index; `arguments` is concatenated across
/// every subsequent delta with the same index.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PartialToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// Apply a streaming tool-call delta to the accumulator.
pub fn absorb_tool_call_delta(
    accumulator: &mut BTreeMap<u32, PartialToolCall>,
    delta: ToolCallDelta,
) {
    let entry = accumulator.entry(delta.index).or_default();
    if let Some(id) = delta.id {
        entry.id = id;
    }
    if let Some(function) = delta.function {
        if let Some(name) = function.name {
            entry.name = name;
        }
        if let Some(arguments) = function.arguments {
            entry.arguments.push_str(&arguments);
        }
    }
}

/// Convert the index-keyed accumulator into the assistant-message tool-call
/// list. Ordering follows the index, matching how providers emit the calls.
#[must_use]
pub fn finalize_tool_calls(accumulator: BTreeMap<u32, PartialToolCall>) -> Vec<AssistantToolCall> {
    accumulator
        .into_values()
        .map(|partial| AssistantToolCall {
            id: partial.id,
            kind: AssistantToolCallKind::Function,
            function: AssistantToolCallFunction {
                name: partial.name,
                arguments: partial.arguments,
            },
        })
        .collect()
}

fn read_text_file_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_READ_TEXT_FILE.to_owned(),
            description: Some(
                "Read a text file from the workspace. Relative paths resolve \
                 against the project root."
                    .to_owned(),
            ),
            parameters: json!({
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file (absolute or relative to project root)."
                    },
                    "line": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "1-based line number to start reading from."
                    },
                    "limit": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Maximum number of lines to read."
                    }
                },
                "required": ["path"],
                "additionalProperties": false
            }),
        },
    }
}

fn write_text_file_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_WRITE_TEXT_FILE.to_owned(),
            description: Some(
                "Write a text file inside the run surface. Writes outside the \
                 surface or to control files are rejected."
                    .to_owned(),
            ),
            parameters: json!({
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to the file (absolute or relative to project root)."
                    },
                    "content": {
                        "type": "string",
                        "description": "Full file contents to write."
                    }
                },
                "required": ["path", "content"],
                "additionalProperties": false
            }),
        },
    }
}

fn create_terminal_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_CREATE_TERMINAL.to_owned(),
            description: Some(
                "Spawn a shell command in a managed terminal and return its id. \
                 Denied binaries and surface escapes are rejected."
                    .to_owned(),
            ),
            parameters: json!({
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "Program to spawn." },
                    "args": {
                        "type": "array",
                        "items": { "type": "string" },
                        "description": "Arguments passed to the program."
                    },
                    "cwd": {
                        "type": "string",
                        "description": "Working directory (relative to project root or absolute)."
                    },
                    "output_byte_limit": {
                        "type": "integer",
                        "minimum": 1,
                        "description": "Maximum captured output bytes; older bytes are dropped."
                    }
                },
                "required": ["command"],
                "additionalProperties": false
            }),
        },
    }
}

fn terminal_output_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_TERMINAL_OUTPUT.to_owned(),
            description: Some(
                "Read the current captured output from a terminal. Returns the \
                 retained bytes and the exit status once the process completes."
                    .to_owned(),
            ),
            parameters: terminal_id_schema(),
        },
    }
}

fn wait_for_terminal_exit_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_WAIT_FOR_TERMINAL_EXIT.to_owned(),
            description: Some("Block until a terminal exits and return its status.".to_owned()),
            parameters: terminal_id_schema(),
        },
    }
}

fn kill_terminal_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_KILL_TERMINAL.to_owned(),
            description: Some("Send SIGKILL to a terminal without releasing it.".to_owned()),
            parameters: terminal_id_schema(),
        },
    }
}

fn release_terminal_definition() -> ToolDefinition {
    ToolDefinition {
        kind: ToolDefinitionKind::Function,
        function: ToolDefinitionFunction {
            name: TOOL_RELEASE_TERMINAL.to_owned(),
            description: Some("Release a terminal's id slot for reuse.".to_owned()),
            parameters: terminal_id_schema(),
        },
    }
}

fn terminal_id_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "terminal_id": { "type": "string", "description": "Terminal id from create_terminal." }
        },
        "required": ["terminal_id"],
        "additionalProperties": false
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openrouter::ToolCallFunctionDelta;

    #[test]
    fn catalog_lists_every_tool_once() {
        let names: Vec<_> = tool_catalog()
            .into_iter()
            .map(|def| def.function.name)
            .collect();
        assert_eq!(
            names,
            vec![
                TOOL_READ_TEXT_FILE,
                TOOL_WRITE_TEXT_FILE,
                TOOL_CREATE_TERMINAL,
                TOOL_TERMINAL_OUTPUT,
                TOOL_WAIT_FOR_TERMINAL_EXIT,
                TOOL_KILL_TERMINAL,
                TOOL_RELEASE_TERMINAL,
            ]
        );
    }

    #[test]
    fn accumulator_concatenates_arguments_by_index() {
        let mut acc = BTreeMap::<u32, PartialToolCall>::new();
        absorb_tool_call_delta(
            &mut acc,
            ToolCallDelta {
                index: 0,
                id: Some("call_a".to_owned()),
                kind: None,
                function: Some(ToolCallFunctionDelta {
                    name: Some(TOOL_READ_TEXT_FILE.to_owned()),
                    arguments: Some("{\"pa".to_owned()),
                }),
            },
        );
        absorb_tool_call_delta(
            &mut acc,
            ToolCallDelta {
                index: 0,
                id: None,
                kind: None,
                function: Some(ToolCallFunctionDelta {
                    name: None,
                    arguments: Some("th\":\"x.txt\"}".to_owned()),
                }),
            },
        );
        let calls = finalize_tool_calls(acc);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].id, "call_a");
        assert_eq!(calls[0].function.name, TOOL_READ_TEXT_FILE);
        assert_eq!(calls[0].function.arguments, "{\"path\":\"x.txt\"}");
    }

    #[test]
    fn accumulator_preserves_index_ordering() {
        let mut acc = BTreeMap::<u32, PartialToolCall>::new();
        absorb_tool_call_delta(
            &mut acc,
            ToolCallDelta {
                index: 1,
                id: Some("second".to_owned()),
                kind: None,
                function: Some(ToolCallFunctionDelta {
                    name: Some(TOOL_WRITE_TEXT_FILE.to_owned()),
                    arguments: Some("{}".to_owned()),
                }),
            },
        );
        absorb_tool_call_delta(
            &mut acc,
            ToolCallDelta {
                index: 0,
                id: Some("first".to_owned()),
                kind: None,
                function: Some(ToolCallFunctionDelta {
                    name: Some(TOOL_READ_TEXT_FILE.to_owned()),
                    arguments: Some("{}".to_owned()),
                }),
            },
        );
        let calls = finalize_tool_calls(acc);
        assert_eq!(calls[0].id, "first");
        assert_eq!(calls[1].id, "second");
    }
}
