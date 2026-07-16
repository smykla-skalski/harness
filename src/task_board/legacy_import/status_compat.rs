use std::path::{Path, PathBuf};

use serde_json::Value;

use super::super::orchestrator::TaskBoardOrchestratorState;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;

pub(super) fn load_orchestrator_state(
    root: &Path,
    name: &str,
    source_paths: &mut Vec<PathBuf>,
) -> Result<TaskBoardOrchestratorState, CliError> {
    let path = root.join(name);
    if !path.exists() {
        return Ok(TaskBoardOrchestratorState::default());
    }
    super::ensure_plain_file(&path, "legacy task board document")?;
    source_paths.push(path.clone());
    let mut document: Value = read_json_typed(&path)?;
    normalize_status_fields(&mut document);
    serde_json::from_value(document).map_err(|error| {
        CliErrorKind::invalid_json(path.display().to_string()).with_details(error.to_string())
    })
}

fn normalize_status_fields(value: &mut Value) {
    match value {
        Value::Array(values) => {
            for value in values {
                normalize_status_fields(value);
            }
        }
        Value::Object(fields) => {
            for (key, value) in fields {
                if is_task_board_status_key(key) && value.as_str() == Some("umbrella") {
                    *value = Value::String("backlog".to_string());
                } else {
                    normalize_status_fields(value);
                }
            }
        }
        _ => {}
    }
}

fn is_task_board_status_key(key: &str) -> bool {
    matches!(key, "status" | "board_status" | "from_status" | "to_status")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_state_normalizes_task_board_status_fields_only() {
        let mut document = serde_json::json!({
            "status": "umbrella",
            "records": [{
                "board_status": "umbrella",
                "label": "umbrella"
            }]
        });

        normalize_status_fields(&mut document);

        assert_eq!(document["status"], "backlog");
        assert_eq!(document["records"][0]["board_status"], "backlog");
        assert_eq!(document["records"][0]["label"], "umbrella");
    }
}
