use std::collections::BTreeSet;
use std::env;
use std::io;
use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::workspace::utc_now;

use super::types::AgentMode;

const REGISTRY_DIR: &str = "machines";
const LOCAL_ID_FILE: &str = "local.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Machine {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub project_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub agent_modes: Vec<AgentMode>,
    pub last_seen: String,
}

impl Machine {
    #[must_use]
    pub fn new(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            project_types: Vec::new(),
            agent_modes: Vec::new(),
            last_seen: utc_now(),
        }
    }

    #[must_use]
    pub fn accepts_project_type(&self, project_type: Option<&str>) -> bool {
        let Some(project_type) = project_type else {
            return true;
        };
        if self.project_types.is_empty() {
            return true;
        }
        self.project_types
            .iter()
            .any(|declared| declared.trim().eq_ignore_ascii_case(project_type.trim()))
    }

    #[must_use]
    pub fn accepts_any(&self, project_types: &[String]) -> bool {
        if project_types.is_empty() {
            return true;
        }
        project_types
            .iter()
            .any(|target| self.accepts_project_type(Some(target.as_str())))
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct LocalIdFile {
    id: String,
}

#[derive(Debug, Clone)]
pub struct MachineRegistry {
    root: PathBuf,
}

impl MachineRegistry {
    #[must_use]
    pub fn new(board_root: impl Into<PathBuf>) -> Self {
        Self {
            root: board_root.into().join(REGISTRY_DIR),
        }
    }

    fn ensure_dir(&self) -> Result<(), CliError> {
        if !self.root.exists() {
            fs::create_dir_all(&self.root)
                .map_err(|error| io_error("create machine registry dir", &self.root, error))?;
        }
        Ok(())
    }

    fn machine_path(&self, id: &str) -> PathBuf {
        self.root.join(format!("{id}.json"))
    }

    fn local_id_path(&self) -> PathBuf {
        self.root.join(LOCAL_ID_FILE)
    }

    /// List every registered machine sorted by id.
    ///
    /// # Errors
    /// Returns `CliError` when the registry directory cannot be read.
    pub fn list(&self) -> Result<Vec<Machine>, CliError> {
        if !self.root.exists() {
            return Ok(Vec::new());
        }
        let entries = fs::read_dir(&self.root)
            .map_err(|error| io_error("list machine registry", &self.root, error))?;
        let mut machines = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|error| io_error("read entry", &self.root, error))?;
            let path = entry.path();
            if path.file_name().is_some_and(|name| name == LOCAL_ID_FILE) {
                continue;
            }
            if path.extension().is_some_and(|ext| ext == "json") {
                let machine: Machine = read_json_typed(&path)?;
                machines.push(machine);
            }
        }
        machines.sort_by(|left, right| left.id.cmp(&right.id));
        Ok(machines)
    }

    /// Return the machine record for `id`, if any.
    ///
    /// # Errors
    /// Returns `CliError` when the file exists but cannot be parsed.
    pub fn get(&self, id: &str) -> Result<Option<Machine>, CliError> {
        let path = self.machine_path(id);
        if !path.exists() {
            return Ok(None);
        }
        let machine: Machine = read_json_typed(&path)?;
        Ok(Some(machine))
    }

    /// Persist a machine, refreshing `last_seen` to now.
    ///
    /// # Errors
    /// Returns `CliError` when the registry directory or file cannot be written.
    pub fn upsert(&self, machine: &Machine) -> Result<Machine, CliError> {
        self.ensure_dir()?;
        let mut stored = machine.clone();
        stored.project_types = normalize_strings(&stored.project_types);
        stored.last_seen = utc_now();
        write_json_pretty(&self.machine_path(&stored.id), &stored)?;
        Ok(stored)
    }

    /// Drop a machine from the registry.
    ///
    /// # Errors
    /// Returns `CliError` when removing the file fails (for non-missing reasons).
    pub fn remove(&self, id: &str) -> Result<(), CliError> {
        let path = self.machine_path(id);
        if !path.exists() {
            return Ok(());
        }
        fs::remove_file(&path).map_err(|error| io_error("remove machine", &path, error))?;
        Ok(())
    }

    /// Return the registered local machine, creating an empty record if missing.
    ///
    /// # Errors
    /// Returns `CliError` when the local id pointer or machine record cannot be read or written.
    pub fn ensure_local(&self) -> Result<Machine, CliError> {
        self.ensure_dir()?;
        let id = self.load_or_init_local_id()?;
        if let Some(machine) = self.get(&id)? {
            return Ok(machine);
        }
        let machine = Machine::new(id, default_label());
        self.upsert(&machine)
    }

    /// Update `last_seen` on the local machine record.
    ///
    /// # Errors
    /// Returns `CliError` when the registry or record cannot be written.
    pub fn touch_local(&self) -> Result<Machine, CliError> {
        let machine = self.ensure_local()?;
        self.upsert(&machine)
    }

    fn load_or_init_local_id(&self) -> Result<String, CliError> {
        let path = self.local_id_path();
        if path.exists() {
            let file: LocalIdFile = read_json_typed(&path)?;
            if !file.id.trim().is_empty() {
                return Ok(file.id);
            }
        }
        let id = generate_local_id();
        write_json_pretty(&path, &LocalIdFile { id: id.clone() })?;
        Ok(id)
    }
}

fn normalize_strings(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(values.len());
    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        let key = trimmed.to_ascii_lowercase();
        if seen.insert(key) {
            out.push(trimmed.to_owned());
        }
    }
    out
}

fn default_label() -> String {
    env::var("HARNESS_MACHINE_LABEL")
        .ok()
        .and_then(|value| {
            let trimmed = value.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_owned())
        })
        .or_else(|| {
            env::var("HOSTNAME").ok().and_then(|value| {
                let trimmed = value.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_owned())
            })
        })
        .unwrap_or_else(|| "local".to_string())
}

fn generate_local_id() -> String {
    Uuid::new_v4().simple().to_string()
}

fn io_error(action: &str, path: &Path, error: io::Error) -> CliError {
    CliError::new(CliErrorKind::workflow_io(format!(
        "task-board machine registry {action} '{}': {error}",
        path.display()
    )))
    .with_source(error)
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn list_returns_empty_when_directory_missing() {
        let temp = tempdir().expect("tempdir");
        let registry = MachineRegistry::new(temp.path());

        assert!(registry.list().expect("list").is_empty());
    }

    #[test]
    fn upsert_persists_and_round_trips_machine() {
        let temp = tempdir().expect("tempdir");
        let registry = MachineRegistry::new(temp.path());

        let stored = registry
            .upsert(&Machine {
                id: "host-a".into(),
                label: "Host A".into(),
                project_types: vec![" web ".into(), "WEB".into(), " backend ".into()],
                agent_modes: vec![AgentMode::Headless],
                last_seen: "2026-05-15T00:00:00Z".into(),
            })
            .expect("upsert");

        assert_eq!(stored.id, "host-a");
        assert_eq!(stored.project_types, vec!["web".to_string(), "backend".to_string()]);
        let machines = registry.list().expect("list");
        assert_eq!(machines.len(), 1);
        assert_eq!(machines[0].id, "host-a");
    }

    #[test]
    fn ensure_local_creates_stable_id_across_calls() {
        let temp = tempdir().expect("tempdir");
        let registry = MachineRegistry::new(temp.path());

        let first = registry.ensure_local().expect("first ensure");
        let second = registry.ensure_local().expect("second ensure");

        assert_eq!(first.id, second.id);
    }

    #[test]
    fn accepts_project_type_matches_case_insensitively() {
        let machine = Machine {
            id: "m".into(),
            label: "m".into(),
            project_types: vec!["WEB".into()],
            agent_modes: Vec::new(),
            last_seen: utc_now(),
        };

        assert!(machine.accepts_project_type(Some("web")));
        assert!(machine.accepts_project_type(Some(" WEB ")));
        assert!(!machine.accepts_project_type(Some("data")));
        assert!(machine.accepts_project_type(None));
    }

    #[test]
    fn accepts_any_handles_empty_targets_and_intersection() {
        let machine = Machine {
            id: "m".into(),
            label: "m".into(),
            project_types: vec!["web".into(), "data".into()],
            agent_modes: Vec::new(),
            last_seen: utc_now(),
        };

        assert!(machine.accepts_any(&[]));
        assert!(machine.accepts_any(&["data".into(), "other".into()]));
        assert!(!machine.accepts_any(&["mobile".into()]));
    }

    #[test]
    fn machine_with_empty_project_types_accepts_any_target() {
        let machine = Machine {
            id: "m".into(),
            label: "m".into(),
            project_types: Vec::new(),
            agent_modes: Vec::new(),
            last_seen: utc_now(),
        };

        assert!(machine.accepts_any(&["anything".into()]));
        assert!(machine.accepts_project_type(Some("anything")));
    }
}
