use serde_json::Value;

/// Summarize the tool input in a stable audit-friendly form.
#[must_use]
pub fn summarize_tool_input(tool_name: &str, tool_input: &Value) -> String {
    match tool_name {
        "Bash" => string_field(tool_input, "command"),
        "Read" | "Write" | "Edit" => summarize_file_paths(tool_input),
        "Glob" => string_field(tool_input, "pattern"),
        "Agent" => first_non_empty_string(
            tool_input,
            &["description", "prompt", "task", "message", "goal"],
        ),
        "AskUserQuestion" => summarize_questions(tool_input),
        _ => normalize_json_value(tool_input),
    }
}

/// Normalize the full tool output that is written to the audit artifact.
#[must_use]
pub fn normalize_tool_output(tool_name: &str, tool_response: &Value) -> String {
    match tool_name {
        "Bash" => {
            let stdout = string_field(tool_response, "stdout");
            let stderr = string_field(tool_response, "stderr");
            let exit_code = tool_response
                .get("exit_code")
                .or_else(|| tool_response.get("exitCode"))
                .and_then(Value::as_i64)
                .unwrap_or_default();
            format!("exit code: {exit_code}\n--- STDOUT ---\n{stdout}\n--- STDERR ---\n{stderr}")
        }
        "AskUserQuestion" => summarize_answers(tool_response),
        _ => normalize_json_value(tool_response),
    }
}

fn summarize_file_paths(tool_input: &Value) -> String {
    let mut paths = Vec::new();
    if let Some(path) = tool_input.get("file_path").and_then(Value::as_str) {
        paths.push(path.to_string());
    }
    if let Some(values) = tool_input.get("file_paths").and_then(Value::as_array) {
        paths.extend(values.iter().filter_map(Value::as_str).map(str::to_string));
    }
    if paths.is_empty() {
        normalize_json_value(tool_input)
    } else {
        paths.join(", ")
    }
}

fn summarize_questions(tool_input: &Value) -> String {
    let Some(questions) = tool_input.get("questions").and_then(Value::as_array) else {
        return normalize_json_value(tool_input);
    };
    let prompts = questions
        .iter()
        .filter_map(|question| question.get("question").and_then(Value::as_str))
        .map(question_head)
        .filter(|question| !question.is_empty())
        .collect::<Vec<_>>();
    if prompts.is_empty() {
        normalize_json_value(tool_input)
    } else {
        prompts.join(" | ")
    }
}

pub(super) fn summarize_answers(tool_response: &Value) -> String {
    let Some(answers) = tool_response.get("answers").and_then(Value::as_array) else {
        return normalize_json_value(tool_response);
    };
    let rendered = answers
        .iter()
        .filter_map(|answer| {
            let question = answer.get("question").and_then(Value::as_str)?;
            let value = answer.get("answer").and_then(Value::as_str)?;
            Some(format!("{} => {value}", question_head(question)))
        })
        .collect::<Vec<_>>();
    if rendered.is_empty() {
        normalize_json_value(tool_response)
    } else {
        rendered.join("\n")
    }
}

fn question_head(question: &str) -> &str {
    question.lines().next().unwrap_or(question).trim()
}

fn string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn first_non_empty_string(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        let field = string_field(value, key);
        if !field.is_empty() {
            return field;
        }
    }
    normalize_json_value(value)
}

fn normalize_json_value(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
    }
}
