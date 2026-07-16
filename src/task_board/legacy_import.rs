//! Pure readers for the one-time file-to-database Task Board migration.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::machines::Machine;
use super::orchestrator::{
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorState, parse_persisted_settings_read_only,
};
use super::policy_graph::{
    POLICY_CANVAS_WORKSPACE_VERSION, POLICY_GRAPH_SCHEMA_VERSION, PolicyCanvasWorkspace,
    PolicyGraph, PolicyPipelineSimulationResult,
};
use super::policy_runtime::handoff_outbox::{
    HandoffRecord, POLICY_HANDOFF_OUTBOX_SCHEMA_VERSION, PolicyHandoffOutboxDocument,
};
use super::policy_runtime::inbox::{POLICY_EVENT_INBOX_SCHEMA_VERSION, PolicyEventInboxDocument};
use super::policy_runtime::models::{
    POLICY_WORKFLOW_RUNS_SCHEMA_VERSION, PolicyWorkflowRun, PolicyWorkflowRunsDocument,
};
use super::policy_runtime::notification::{
    NotificationRecord, POLICY_NOTIFICATION_OUTBOX_SCHEMA_VERSION, PolicyNotificationOutboxDocument,
};
use super::policy_runtime::task_creation::{
    POLICY_TASK_CREATION_OUTBOX_SCHEMA_VERSION, PolicyTaskCreationOutboxDocument,
    TaskCreationRecord,
};
use super::store::{apply_canonical_persisted_status, read_path, validate_loaded_id};
use super::types::{CURRENT_TASK_BOARD_ITEM_VERSION, TaskBoardItem};
use crate::errors::{CliError, CliErrorKind, io_for};
use crate::infra::io::read_json_typed;

mod status_compat;

const SETTINGS_FILE: &str = "orchestrator-settings.json";
const STATE_FILE: &str = "orchestrator-state.json";
const RUNS_FILE: &str = "policy-workflow-runs-v1.json";
const EVENTS_FILE: &str = "policy-event-inbox-v1.json";
const HANDOFF_FILE: &str = "policy-handoff-outbox-v1.json";
const NOTIFICATION_FILE: &str = "policy-notification-outbox-v1.json";
const TASK_CREATION_FILE: &str = "policy-task-creation-outbox-v1.json";
const CANVAS_WORKSPACE_FILE: &str = "policy-canvases-v1.json";
const LEGACY_PIPELINE_FILE: &str = "policy-pipeline-v2.json";
const LEGACY_SIMULATION_FILE: &str = "policy-pipeline-v2-simulation.json";

#[derive(Debug)]
pub(crate) struct LegacyTaskBoardSnapshot {
    pub(crate) items: Vec<TaskBoardItem>,
    pub(crate) machines: Vec<Machine>,
    pub(crate) local_machine_id: Option<String>,
    pub(crate) settings: TaskBoardOrchestratorSettings,
    pub(crate) state: TaskBoardOrchestratorState,
    pub(crate) policy_runs: Vec<PolicyWorkflowRun>,
    pub(crate) policy_events: Vec<super::policy_runtime::models::PolicyWorkflowEvent>,
    pub(crate) handoffs: Vec<HandoffRecord>,
    pub(crate) notifications: Vec<NotificationRecord>,
    pub(crate) task_creations: Vec<TaskCreationRecord>,
    pub(crate) policy_workspace: Option<PolicyCanvasWorkspace>,
    pub(crate) source_digest: String,
    pub(crate) canonical_digest: String,
}

#[derive(Serialize)]
struct CanonicalSnapshot<'a> {
    // Policy files stay in `source_digest`: expanding a legacy single pipeline
    // creates workspace IDs and timestamps, so including that expansion here
    // would make crash-recovery marker verification nondeterministic.
    items: &'a [TaskBoardItem],
    machines: &'a [Machine],
    local_machine_id: &'a Option<String>,
    settings: &'a TaskBoardOrchestratorSettings,
    state: &'a TaskBoardOrchestratorState,
    policy_runs: &'a [PolicyWorkflowRun],
    policy_events: &'a [super::policy_runtime::models::PolicyWorkflowEvent],
    handoffs: &'a [HandoffRecord],
    notifications: &'a [NotificationRecord],
    task_creations: &'a [TaskCreationRecord],
}

impl LegacyTaskBoardSnapshot {
    pub(crate) fn load(root: &Path) -> Result<Self, CliError> {
        if !root.exists() {
            return Self::empty();
        }
        ensure_plain_directory(root, "legacy task board root")?;
        validate_root_entries(root)?;
        let mut source_paths = Vec::new();
        let items = load_items(root, &mut source_paths)?;
        let (machines, local_machine_id) = load_machines(root, &mut source_paths)?;
        let settings_path = root.join(SETTINGS_FILE);
        track_if_file(&settings_path, &mut source_paths)?;
        let settings = parse_persisted_settings_read_only(&settings_path)?.unwrap_or_default();
        let state = status_compat::load_orchestrator_state(root, STATE_FILE, &mut source_paths)?;
        let runs: PolicyWorkflowRunsDocument = load_optional(root, RUNS_FILE, &mut source_paths)?;
        ensure_schema(
            RUNS_FILE,
            runs.schema_version,
            POLICY_WORKFLOW_RUNS_SCHEMA_VERSION,
        )?;
        let events: PolicyEventInboxDocument = load_optional(root, EVENTS_FILE, &mut source_paths)?;
        ensure_schema(
            EVENTS_FILE,
            events.schema_version,
            POLICY_EVENT_INBOX_SCHEMA_VERSION,
        )?;
        let handoffs: PolicyHandoffOutboxDocument =
            load_optional(root, HANDOFF_FILE, &mut source_paths)?;
        ensure_schema(
            HANDOFF_FILE,
            handoffs.schema_version,
            POLICY_HANDOFF_OUTBOX_SCHEMA_VERSION,
        )?;
        let notifications: PolicyNotificationOutboxDocument =
            load_optional(root, NOTIFICATION_FILE, &mut source_paths)?;
        ensure_schema(
            NOTIFICATION_FILE,
            notifications.schema_version,
            POLICY_NOTIFICATION_OUTBOX_SCHEMA_VERSION,
        )?;
        let task_creations: PolicyTaskCreationOutboxDocument =
            load_optional(root, TASK_CREATION_FILE, &mut source_paths)?;
        ensure_schema(
            TASK_CREATION_FILE,
            task_creations.schema_version,
            POLICY_TASK_CREATION_OUTBOX_SCHEMA_VERSION,
        )?;
        let policy_workspace = load_policy_workspace(root, &mut source_paths)?;
        let source_digest = digest_source_files(root, &source_paths)?;
        Self::finish(
            items,
            machines,
            local_machine_id,
            settings,
            state,
            runs.runs,
            events.events,
            handoffs.records,
            notifications.records,
            task_creations.records,
            policy_workspace,
            source_digest,
        )
    }

    pub(crate) fn counts(&self) -> BTreeMap<&'static str, usize> {
        BTreeMap::from([
            ("items", self.items.len()),
            ("machines", self.machines.len()),
            ("policy_events", self.policy_events.len()),
            ("policy_runs", self.policy_runs.len()),
            ("handoffs", self.handoffs.len()),
            ("notifications", self.notifications.len()),
            ("task_creations", self.task_creations.len()),
            (
                "policy_canvases",
                self.policy_workspace
                    .as_ref()
                    .map_or(0, |workspace| workspace.canvases.len()),
            ),
        ])
    }

    pub(crate) fn empty() -> Result<Self, CliError> {
        Self::finish(
            Vec::new(),
            Vec::new(),
            None,
            TaskBoardOrchestratorSettings::default(),
            TaskBoardOrchestratorState::default(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            None,
            hex::encode(Sha256::digest([])),
        )
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "the importer assembles every legacy aggregate exactly once"
    )]
    fn finish(
        items: Vec<TaskBoardItem>,
        machines: Vec<Machine>,
        local_machine_id: Option<String>,
        settings: TaskBoardOrchestratorSettings,
        state: TaskBoardOrchestratorState,
        policy_runs: Vec<PolicyWorkflowRun>,
        policy_events: Vec<super::policy_runtime::models::PolicyWorkflowEvent>,
        handoffs: Vec<HandoffRecord>,
        notifications: Vec<NotificationRecord>,
        task_creations: Vec<TaskCreationRecord>,
        policy_workspace: Option<PolicyCanvasWorkspace>,
        source_digest: String,
    ) -> Result<Self, CliError> {
        let canonical = CanonicalSnapshot {
            items: &items,
            machines: &machines,
            local_machine_id: &local_machine_id,
            settings: &settings,
            state: &state,
            policy_runs: &policy_runs,
            policy_events: &policy_events,
            handoffs: &handoffs,
            notifications: &notifications,
            task_creations: &task_creations,
        };
        let canonical_bytes = serde_json::to_vec(&canonical).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("serialize legacy task board: {error}"))
        })?;
        Ok(Self {
            items,
            machines,
            local_machine_id,
            settings,
            state,
            policy_runs,
            policy_events,
            handoffs,
            notifications,
            task_creations,
            policy_workspace,
            source_digest,
            canonical_digest: hex::encode(Sha256::digest(canonical_bytes)),
        })
    }
}

fn load_items(
    root: &Path,
    source_paths: &mut Vec<PathBuf>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let dir = root.join("tasks");
    if !dir.exists() {
        return Ok(Vec::new());
    }
    ensure_plain_directory(&dir, "legacy task board items")?;
    let mut paths = directory_entries(&dir)?;
    paths.sort();
    let mut ids = BTreeSet::new();
    let mut items = Vec::with_capacity(paths.len());
    for path in paths {
        ensure_plain_file(&path, "legacy task board item")?;
        if path.extension().and_then(|value| value.to_str()) != Some("md") {
            return Err(unexpected_path(&path));
        }
        let id = path
            .file_stem()
            .and_then(|value| value.to_str())
            .ok_or_else(|| unexpected_path(&path))?;
        let mut item = read_path(&path)?;
        validate_loaded_id(id, &item)?;
        ensure_schema(
            &path.display().to_string(),
            item.schema_version,
            CURRENT_TASK_BOARD_ITEM_VERSION,
        )?;
        if !ids.insert(item.id.clone()) {
            return Err(duplicate_id("task board item", &item.id));
        }
        apply_canonical_persisted_status(&mut item);
        source_paths.push(path);
        items.push(item);
    }
    Ok(items)
}

fn load_machines(
    root: &Path,
    source_paths: &mut Vec<PathBuf>,
) -> Result<(Vec<Machine>, Option<String>), CliError> {
    let dir = root.join("machines");
    if !dir.exists() {
        return Ok((Vec::new(), None));
    }
    ensure_plain_directory(&dir, "legacy machine registry")?;
    let mut paths = directory_entries(&dir)?;
    paths.sort();
    let mut machines = Vec::new();
    let mut ids = BTreeSet::new();
    let mut local_id = None;
    for path in paths {
        ensure_plain_file(&path, "legacy machine record")?;
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            return Err(unexpected_path(&path));
        }
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if name == "local.json" {
            let pointer: LocalMachinePointer = read_json_typed(&path)?;
            if pointer.id.trim().is_empty() {
                return Err(CliErrorKind::workflow_parse("local machine id is empty").into());
            }
            local_id = Some(pointer.id);
        } else {
            let machine: Machine = read_json_typed(&path)?;
            let expected = path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("");
            if machine.id != expected {
                return Err(CliErrorKind::workflow_parse(format!(
                    "machine file id mismatch: expected '{expected}', found '{}'",
                    machine.id
                ))
                .into());
            }
            if !ids.insert(machine.id.clone()) {
                return Err(duplicate_id("machine", &machine.id));
            }
            machines.push(machine);
        }
        source_paths.push(path);
    }
    Ok((machines, local_id))
}

#[derive(Deserialize)]
struct LocalMachinePointer {
    id: String,
}

fn load_optional<T: Default + DeserializeOwned>(
    root: &Path,
    name: &str,
    source_paths: &mut Vec<PathBuf>,
) -> Result<T, CliError> {
    let path = root.join(name);
    if !path.exists() {
        return Ok(T::default());
    }
    ensure_plain_file(&path, "legacy task board document")?;
    source_paths.push(path.clone());
    read_json_typed(&path)
}

fn load_policy_workspace(
    root: &Path,
    source_paths: &mut Vec<PathBuf>,
) -> Result<Option<PolicyCanvasWorkspace>, CliError> {
    let workspace_path = root.join(CANVAS_WORKSPACE_FILE);
    let pipeline_path = root.join(LEGACY_PIPELINE_FILE);
    let simulation_path = root.join(LEGACY_SIMULATION_FILE);
    if workspace_path.exists() {
        track_if_file(&workspace_path, source_paths)?;
        track_if_file(&pipeline_path, source_paths)?;
        track_if_file(&simulation_path, source_paths)?;
        let workspace: PolicyCanvasWorkspace = read_json_typed(&workspace_path)?;
        ensure_schema(
            CANVAS_WORKSPACE_FILE,
            workspace.schema_version,
            POLICY_CANVAS_WORKSPACE_VERSION,
        )?;
        return Ok(Some(workspace));
    }
    if !pipeline_path.exists() {
        if simulation_path.exists() {
            return Err(CliErrorKind::workflow_parse(
                "legacy policy simulation exists without its pipeline document",
            )
            .into());
        }
        return Ok(None);
    }
    track_if_file(&pipeline_path, source_paths)?;
    track_if_file(&simulation_path, source_paths)?;
    let document: PolicyGraph = read_json_typed(&pipeline_path)?;
    if document.schema_version != POLICY_GRAPH_SCHEMA_VERSION {
        return Err(CliErrorKind::workflow_version(format!(
            "{LEGACY_PIPELINE_FILE} uses unsupported schema v{}; expected v{POLICY_GRAPH_SCHEMA_VERSION}",
            document.schema_version
        ))
        .into());
    }
    let simulation = simulation_path
        .exists()
        .then(|| read_json_typed::<PolicyPipelineSimulationResult>(&simulation_path))
        .transpose()?;
    Ok(Some(PolicyCanvasWorkspace::from_legacy(
        document, simulation,
    )))
}

fn validate_root_entries(root: &Path) -> Result<(), CliError> {
    for path in directory_entries(root)? {
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if allowed_root_entry(name) {
            continue;
        }
        return Err(unexpected_path(&path));
    }
    Ok(())
}

fn allowed_root_entry(name: &str) -> bool {
    matches!(
        name,
        ".mutation.lock"
            | "tasks"
            | "machines"
            | "backups"
            | SETTINGS_FILE
            | STATE_FILE
            | RUNS_FILE
            | EVENTS_FILE
            | HANDOFF_FILE
            | NOTIFICATION_FILE
            | TASK_CREATION_FILE
            | CANVAS_WORKSPACE_FILE
            | LEGACY_PIPELINE_FILE
            | LEGACY_SIMULATION_FILE
            | "policy-canvases-v1.json.imported.bak"
    ) || name.starts_with("policy-canvases-v1.json.bak-")
        || name.ends_with(".json.lock")
}

fn track_if_file(path: &Path, source_paths: &mut Vec<PathBuf>) -> Result<(), CliError> {
    if path.exists() {
        ensure_plain_file(path, "legacy task board document")?;
        source_paths.push(path.to_path_buf());
    }
    Ok(())
}

fn digest_source_files(root: &Path, paths: &[PathBuf]) -> Result<String, CliError> {
    let mut paths = paths.to_vec();
    paths.sort();
    let mut digest = Sha256::new();
    for path in paths {
        let relative = path.strip_prefix(root).unwrap_or(&path);
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        digest.update(fs::read(&path).map_err(|error| io_for("read", &path, &error))?);
        digest.update([0]);
    }
    Ok(hex::encode(digest.finalize()))
}

fn directory_entries(path: &Path) -> Result<Vec<PathBuf>, CliError> {
    fs::read_dir(path)
        .map_err(|error| io_for("read dir", path, &error))?
        .map(|entry| {
            entry
                .map(|entry| entry.path())
                .map_err(|error| CliError::from(io_for("read dir entry", path, &error)))
        })
        .collect()
}

fn ensure_plain_directory(path: &Path, context: &str) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| io_for("stat", path, &error))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CliErrorKind::workflow_parse(format!(
            "{context} must be a plain directory: {}",
            path.display()
        ))
        .into());
    }
    Ok(())
}

fn ensure_plain_file(path: &Path, context: &str) -> Result<(), CliError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| io_for("stat", path, &error))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CliErrorKind::workflow_parse(format!(
            "{context} must be a plain file: {}",
            path.display()
        ))
        .into());
    }
    Ok(())
}

fn ensure_schema(label: &str, found: u32, expected: u32) -> Result<(), CliError> {
    if found == expected {
        return Ok(());
    }
    Err(CliErrorKind::workflow_version(format!(
        "{label} uses unsupported schema v{found}; expected v{expected}"
    ))
    .into())
}

fn duplicate_id(kind: &str, id: &str) -> CliError {
    CliErrorKind::workflow_parse(format!("duplicate legacy {kind} id '{id}'")).into()
}

fn unexpected_path(path: &Path) -> CliError {
    CliErrorKind::workflow_parse(format!(
        "unexpected legacy task board entry: {}",
        path.display()
    ))
    .into()
}
