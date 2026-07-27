use std::collections::BTreeSet;
use std::path::Path;

use serde_json::Value;

use crate::infra::io::read_json_typed;
use crate::task_board::types::TaskBoardStatus;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::types::TaskBoardOrchestratorSettings;

/// Parse legacy settings with the same canonicalization as the live loader,
/// without rewriting the source. Used by the one-time database importer.
pub(crate) fn parse_persisted_settings_read_only(
    path: &Path,
) -> Result<Option<TaskBoardOrchestratorSettings>, CliError> {
    if !path.exists() {
        return Ok(None);
    }
    let mut document: Value = read_json_typed(path)?;
    normalize_enabled_workflows(&mut document);
    repair_dispatch_status_filter(&mut document);
    serde_json::from_value(document).map(Some).map_err(|error| {
        CliErrorKind::invalid_json(path.display().to_string())
            .with_details(error.to_string())
    })
}

fn normalize_enabled_workflows(document: &mut Value) {
    let Some(workflows) = document
        .as_object_mut()
        .and_then(|map| map.get_mut("enabled_workflows"))
        .and_then(Value::as_array_mut)
    else {
        return;
    };
    let mut seen = BTreeSet::new();
    let mut normalized = Vec::with_capacity(workflows.len());
    for entry in workflows.drain(..) {
        let Some(raw) = entry.as_str() else {
            normalized.push(entry);
            continue;
        };
        let canonical = if raw == "dependency_update" {
            "review"
        } else {
            raw
        };
        if seen.insert(canonical.to_owned()) {
            normalized.push(Value::String(canonical.to_owned()));
        }
    }
    *workflows = normalized;
}

fn repair_dispatch_status_filter(document: &mut Value) {
    let Some(status_value) = document
        .as_object()
        .and_then(|map| map.get("dispatch_status_filter"))
        .cloned()
    else {
        return;
    };
    if matches!(status_value.as_str(), Some("umbrella" | "backlog")) {
        document["dispatch_status_filter"] = Value::String("inbox".to_owned());
        return;
    }
    let Ok(status) = serde_json::from_value::<TaskBoardStatus>(status_value) else {
        return;
    };
    let canonical = status.canonical_persisted_status();
    if status != canonical
        && let Ok(canonical_value) = serde_json::to_value(canonical)
    {
        document["dispatch_status_filter"] = canonical_value;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::{TaskBoardOrchestratorWorkflow, TaskBoardStatus};

    #[test]
    fn legacy_import_canonicalizes_settings_without_rewriting_source() {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join("orchestrator-settings.json");
        let source = r#"{
            "enabled_workflows": ["dependency_update", "review"],
            "dispatch_status_filter": "needs_you"
        }"#;
        fs_err::write(&path, source).expect("write settings");

        let settings = parse_persisted_settings_read_only(&path)
            .expect("parse settings")
            .expect("settings");

        assert_eq!(
            settings.enabled_workflows,
            vec![TaskBoardOrchestratorWorkflow::Review]
        );
        assert_eq!(
            settings.dispatch_status_filter,
            Some(TaskBoardStatus::HumanRequired)
        );
        assert_eq!(fs_err::read_to_string(path).expect("read settings"), source);
    }
}
