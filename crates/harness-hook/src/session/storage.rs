use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, validate_safe_segment};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;
use crate::session::types::{CURRENT_VERSION, SessionLogEntry, SessionState, SessionTransition};
use crate::workspace::layout::{SessionLayout, sessions_root};
use crate::workspace::{harness_data_root, ids, project_context_dir, utc_now};

#[path = "../../../../src/session/storage/migrations.rs"]
mod migrations;

#[derive(Debug, Clone, Deserialize, Default)]
pub(super) struct ActiveRegistry {
    #[serde(default)]
    pub(super) sessions: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Deserialize)]
struct ProjectOriginRecord {
    #[serde(default)]
    adopted_session_roots: BTreeMap<String, String>,
}

pub(super) fn layout_from_project_dir(
    project_dir: &Path,
    session_id: &str,
) -> Result<SessionLayout, CliError> {
    let project_name = project_dir
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_project_dir(
                project_dir.display().to_string(),
            ))
        })?;
    Ok(SessionLayout {
        sessions_root: sessions_root(&harness_data_root()),
        project_name,
        session_id: session_id.to_string(),
    })
}

pub(super) fn load_active_registry_for(project_dir: &Path) -> Result<ActiveRegistry, CliError> {
    let layout = layout_from_project_dir(project_dir, "registry-placeholder")?;
    let mut paths = BTreeSet::from([layout.active_registry()]);
    paths.extend(
        adopted_project_dirs(project_dir)
            .into_iter()
            .map(|path| path.join(".active.json")),
    );
    let mut merged = ActiveRegistry::default();
    for path in paths {
        let registry = read_json_typed::<ActiveRegistry>(&path).unwrap_or_default();
        merged.sessions.extend(
            registry
                .sessions
                .into_iter()
                .filter(|(session_id, _)| validate_session_id(session_id).is_ok()),
        );
    }
    Ok(merged)
}

pub(super) fn load_state(layout: &SessionLayout) -> Result<Option<SessionState>, CliError> {
    validate_session_id(&layout.session_id)?;
    state_repository(layout).load()
}

pub(super) fn update_state(
    layout: &SessionLayout,
    update: impl FnOnce(&mut SessionState) -> Result<(), CliError>,
) -> Result<SessionState, CliError> {
    validate_session_id(&layout.session_id)?;
    let session_id = layout.session_id.clone();
    state_repository(layout)
        .update(|state| {
            let mut state = state.ok_or_else(|| {
                CliError::from(CliErrorKind::session_not_active(format!(
                    "harness session '{session_id}' not found"
                )))
            })?;
            state.state_version += 1;
            state.updated_at = utc_now();
            update(&mut state)?;
            Ok(Some(state))
        })?
        .ok_or_else(|| {
            CliErrorKind::session_not_active(format!("harness session '{session_id}' not found"))
                .into()
        })
}

pub(super) fn update_state_if_changed(
    layout: &SessionLayout,
    update: impl FnOnce(&mut SessionState) -> Result<bool, CliError>,
) -> Result<SessionState, CliError> {
    validate_session_id(&layout.session_id)?;
    let session_id = layout.session_id.clone();
    state_repository(layout)
        .update(|state| {
            let mut state = state.ok_or_else(|| {
                CliError::from(CliErrorKind::session_not_active(format!(
                    "harness session '{session_id}' not found"
                )))
            })?;
            if update(&mut state)? {
                state.state_version += 1;
                state.updated_at = utc_now();
            }
            Ok(Some(state))
        })?
        .ok_or_else(|| {
            CliErrorKind::session_not_active(format!("harness session '{session_id}' not found"))
                .into()
        })
}

pub(super) fn append_log_entry(
    layout: &SessionLayout,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    validate_session_id(&layout.session_id)?;
    with_lock(layout, &format!("log-{}", layout.session_id), || {
        let path = layout.log_file();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| storage_error(&error))?;
        }
        let entry = SessionLogEntry {
            sequence: next_log_sequence(&path),
            recorded_at: utc_now(),
            session_id: layout.session_id.clone(),
            transition,
            actor_id: actor_id.map(ToString::to_string),
            reason: reason.map(ToString::to_string),
        };
        append_json_line(&path, &entry)
    })
}

pub(super) fn load_log_entries(layout: &SessionLayout) -> Result<Vec<SessionLogEntry>, CliError> {
    read_json_lines(&layout.log_file(), "session log")
}

fn state_repository(layout: &SessionLayout) -> VersionedJsonRepository<SessionState> {
    use migrations::{
        migrate_v1_to_v2, migrate_v2_to_v3, migrate_v3_to_v4, migrate_v4_to_v5, migrate_v5_to_v6,
        migrate_v6_to_v7, migrate_v7_to_v8, migrate_v8_to_v9, migrate_v9_to_v10,
        migrate_v10_to_v11, migrate_v11_to_v12, migrate_v12_to_v13, migrate_v13_to_v14,
    };

    VersionedJsonRepository::new(layout.state_file(), CURRENT_VERSION).with_migrations(vec![
        Box::new(migrate_v1_to_v2),
        Box::new(migrate_v2_to_v3),
        Box::new(migrate_v3_to_v4),
        Box::new(migrate_v4_to_v5),
        Box::new(migrate_v5_to_v6),
        Box::new(migrate_v6_to_v7),
        Box::new(migrate_v7_to_v8),
        Box::new(migrate_v8_to_v9),
        Box::new(migrate_v9_to_v10),
        Box::new(migrate_v10_to_v11),
        Box::new(migrate_v11_to_v12),
        Box::new(migrate_v12_to_v13),
        Box::new(migrate_v13_to_v14),
    ])
}

fn validate_session_id(session_id: &str) -> Result<(), CliError> {
    validate_safe_segment(session_id)?;
    ids::validate(session_id)
        .map_err(|error| CliErrorKind::workflow_parse(error.to_string()).into())
}

fn adopted_project_dirs(project_dir: &Path) -> BTreeSet<PathBuf> {
    let path = project_context_dir(project_dir).join("project-origin.json");
    let Ok(origin) = read_json_typed::<ProjectOriginRecord>(&path) else {
        return BTreeSet::new();
    };
    origin
        .adopted_session_roots
        .into_values()
        .filter_map(|root| PathBuf::from(root).parent().map(Path::to_path_buf))
        .collect()
}

fn with_lock<T>(
    layout: &SessionLayout,
    name: &str,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    with_exclusive_flock(
        &layout.locks_dir().join(format!("{name}.lock")),
        FlockErrorContext::new("session storage"),
        action,
    )
}

fn append_json_line(path: &Path, value: &impl Serialize) -> Result<(), CliError> {
    let line = serde_json::to_string(value)
        .map_err(|error| CliErrorKind::workflow_serialize(format!("session log: {error}")))?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| storage_error(&error))?;
    writeln!(file, "{line}").map_err(|error| storage_error(&error))
}

fn read_json_lines<T: DeserializeOwned>(path: &Path, label: &str) -> Result<Vec<T>, CliError> {
    if !path.is_file() {
        return Ok(Vec::new());
    }
    fs::read_to_string(path)
        .map_err(|error| storage_error(&error))?
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line)
                .map_err(|error| CliErrorKind::workflow_parse(format!("{label}: {error}")).into())
        })
        .collect()
}

fn next_log_sequence(path: &Path) -> u64 {
    fs::read_to_string(path).map_or(1, |content| {
        content
            .lines()
            .filter(|line| !line.trim().is_empty())
            .count() as u64
            + 1
    })
}

fn storage_error(error: &dyn fmt::Display) -> CliError {
    CliErrorKind::workflow_io(format!("session storage: {error}")).into()
}
