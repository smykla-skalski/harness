use std::path::{Path, PathBuf};

use fs_err as fs;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind, io_for};
use crate::infra::io;
use crate::workspace::{harness_data_root, utc_now};

use super::types::{
    AgentMode, CURRENT_TASK_BOARD_ITEM_VERSION, ExternalRef, ExternalRefProvider, PlanningState,
    TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardWorkflowState,
};

#[derive(Debug, Clone)]
pub struct TaskBoardStore {
    root: PathBuf,
}

#[derive(Debug, Clone, Default)]
pub struct TaskBoardItemPatch {
    pub title: Option<String>,
    pub body: Option<String>,
    pub status: Option<TaskBoardStatus>,
    pub priority: Option<TaskBoardPriority>,
    pub tags: Option<Vec<String>>,
    pub project_id: OptionalFieldPatch<String>,
    pub target_project_types: Option<Vec<String>>,
    pub agent_mode: Option<AgentMode>,
    pub external_refs: Option<Vec<ExternalRef>>,
    pub planning: Option<PlanningState>,
    pub clear_planning: bool,
    /// Clear `approved_by` / `approved_at` while preserving the plan summary.
    /// Mutually exclusive with `clear_planning`; takes effect after `planning`
    /// is merged.
    pub clear_approval: bool,
    pub workflow: Option<TaskBoardWorkflowState>,
    pub clear_workflow: bool,
    pub session_id: OptionalFieldPatch<String>,
    pub work_item_id: OptionalFieldPatch<String>,
}

#[derive(Debug, Clone, Default)]
pub enum OptionalFieldPatch<T> {
    #[default]
    Unchanged,
    Set(T),
    Clear,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TaskBoardFrontmatter {
    schema_version: u32,
    id: String,
    title: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    target_project_types: Vec<String>,
    agent_mode: AgentMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    external_refs: Vec<ExternalRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    imported_from_provider: Option<ExternalRefProvider>,
    #[serde(default)]
    planning: PlanningState,
    #[serde(default, skip_serializing_if = "TaskBoardWorkflowState::is_default")]
    workflow: TaskBoardWorkflowState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    work_item_id: Option<String>,
    #[serde(default)]
    usage: super::types::TaskUsage,
    created_at: String,
    updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    deleted_at: Option<String>,
}

impl From<&TaskBoardItem> for TaskBoardFrontmatter {
    fn from(item: &TaskBoardItem) -> Self {
        Self {
            schema_version: item.schema_version,
            id: item.id.clone(),
            title: item.title.clone(),
            status: item.status,
            priority: item.priority,
            tags: item.tags.clone(),
            project_id: item.project_id.clone(),
            target_project_types: item.target_project_types.clone(),
            agent_mode: item.agent_mode,
            external_refs: item.external_refs.clone(),
            imported_from_provider: item.imported_from_provider,
            planning: item.planning.clone(),
            workflow: item.workflow.clone(),
            session_id: item.session_id.clone(),
            work_item_id: item.work_item_id.clone(),
            usage: item.usage.clone(),
            created_at: item.created_at.clone(),
            updated_at: item.updated_at.clone(),
            deleted_at: item.deleted_at.clone(),
        }
    }
}

impl TaskBoardFrontmatter {
    fn into_item(self, body: String) -> TaskBoardItem {
        TaskBoardItem {
            schema_version: self.schema_version,
            id: self.id,
            title: self.title,
            body,
            status: self.status,
            priority: self.priority,
            tags: self.tags,
            project_id: self.project_id,
            target_project_types: self.target_project_types,
            agent_mode: self.agent_mode,
            external_refs: self.external_refs,
            imported_from_provider: self.imported_from_provider,
            planning: self.planning,
            workflow: self.workflow,
            session_id: self.session_id,
            work_item_id: self.work_item_id,
            usage: self.usage,
            created_at: self.created_at,
            updated_at: self.updated_at,
            deleted_at: self.deleted_at,
        }
    }
}

#[must_use]
pub fn default_board_root() -> PathBuf {
    harness_data_root().join("task-board")
}

impl TaskBoardStore {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    #[must_use]
    pub fn tasks_dir(&self) -> PathBuf {
        self.root.join("tasks")
    }

    /// Create a new board item.
    ///
    /// # Errors
    /// Returns `CliError` if the ID is unsafe, already exists, or the markdown
    /// file cannot be written.
    pub fn create(
        &self,
        title: &str,
        body: &str,
        mut item: TaskBoardItem,
    ) -> Result<TaskBoardItem, CliError> {
        item.title = title.to_string();
        item.body = body.to_string();
        self.validate_new_id(&item.id)?;
        self.save(&item)?;
        Ok(item)
    }

    /// Load one board item by ID.
    ///
    /// # Errors
    /// Returns `CliError` if the ID is unsafe, the file is missing, or the
    /// markdown/frontmatter payload cannot be parsed.
    pub fn get(&self, id: &str) -> Result<TaskBoardItem, CliError> {
        let path = self.path_for(id)?;
        read_path(&path)
    }

    /// List active board items, optionally filtered by status.
    ///
    /// # Errors
    /// Returns `CliError` if the tasks directory cannot be read or an item
    /// cannot be parsed.
    pub fn list(&self, status: Option<TaskBoardStatus>) -> Result<Vec<TaskBoardItem>, CliError> {
        let dir = self.tasks_dir();
        if !dir.exists() {
            return Ok(Vec::new());
        }
        let mut items = Vec::new();
        for entry in fs::read_dir(&dir).map_err(|error| io_for("read dir", &dir, &error))? {
            let path = entry
                .map_err(|error| io_for("read dir entry", &dir, &error))?
                .path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
                continue;
            }
            let item = read_path(&path)?;
            if !item.is_deleted() && status.is_none_or(|target| item.status == target) {
                items.push(item);
            }
        }
        sort_items(&mut items);
        Ok(items)
    }

    /// List every board item on disk including tombstoned ones.
    ///
    /// # Errors
    /// Returns `CliError` if the tasks directory cannot be read or an item
    /// cannot be parsed.
    pub fn list_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        let dir = self.tasks_dir();
        if !dir.exists() {
            return Ok(Vec::new());
        }
        let mut items = Vec::new();
        for entry in fs::read_dir(&dir).map_err(|error| io_for("read dir", &dir, &error))? {
            let path = entry
                .map_err(|error| io_for("read dir entry", &dir, &error))?
                .path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
                continue;
            }
            items.push(read_path(&path)?);
        }
        sort_items(&mut items);
        Ok(items)
    }

    /// Patch one board item in place.
    ///
    /// # Errors
    /// Returns `CliError` if the item cannot be loaded or saved.
    pub fn update(&self, id: &str, patch: TaskBoardItemPatch) -> Result<TaskBoardItem, CliError> {
        let mut item = self.get(id)?;
        apply_patch(&mut item, patch);
        item.updated_at = utc_now();
        self.save(&item)?;
        Ok(item)
    }

    /// Tombstone one board item.
    ///
    /// # Errors
    /// Returns `CliError` if the item cannot be loaded or saved.
    pub fn delete(&self, id: &str) -> Result<TaskBoardItem, CliError> {
        let mut item = self.get(id)?;
        let now = utc_now();
        item.deleted_at = Some(now.clone());
        item.updated_at = now;
        self.save(&item)?;
        Ok(item)
    }

    fn save(&self, item: &TaskBoardItem) -> Result<(), CliError> {
        if item.schema_version != CURRENT_TASK_BOARD_ITEM_VERSION {
            return Err(CliErrorKind::workflow_version(format!(
                "task-board item '{}' uses unsupported schema v{}",
                item.id, item.schema_version
            ))
            .into());
        }
        let path = self.path_for(&item.id)?;
        let frontmatter = TaskBoardFrontmatter::from(item);
        let yaml = serde_yml::to_string(&frontmatter).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("serialize task-board item: {error}"))
        })?;
        io::write_text(&path, &format!("---\n{yaml}---\n\n{}", item.body))?;
        Ok(())
    }

    fn path_for(&self, id: &str) -> Result<PathBuf, CliError> {
        io::validate_safe_segment(id)?;
        Ok(self.tasks_dir().join(format!("{id}.md")))
    }

    fn validate_new_id(&self, id: &str) -> Result<(), CliError> {
        let path = self.path_for(id)?;
        if path.exists() {
            return Err(CliErrorKind::workflow_io(format!(
                "task-board item '{id}' already exists"
            ))
            .into());
        }
        Ok(())
    }
}

fn apply_patch(item: &mut TaskBoardItem, patch: TaskBoardItemPatch) {
    apply_core_patch(item, &patch);
    apply_link_patch(item, patch);
}

fn apply_core_patch(item: &mut TaskBoardItem, patch: &TaskBoardItemPatch) {
    assign_if_some(&mut item.title, patch.title.as_ref());
    assign_if_some(&mut item.body, patch.body.as_ref());
    assign_copy_if_some(&mut item.status, patch.status);
    assign_copy_if_some(&mut item.priority, patch.priority);
    assign_copy_if_some(&mut item.agent_mode, patch.agent_mode);
    assign_if_some(&mut item.tags, patch.tags.as_ref());
    assign_if_some(
        &mut item.target_project_types,
        patch.target_project_types.as_ref(),
    );
    assign_if_some(&mut item.external_refs, patch.external_refs.as_ref());
    if patch.clear_planning {
        item.planning = PlanningState::default();
    } else {
        apply_planning_patch(&mut item.planning, patch.planning.as_ref());
        if patch.clear_approval {
            item.planning.approved_by = None;
            item.planning.approved_at = None;
        }
    }
    if patch.clear_workflow {
        item.workflow = TaskBoardWorkflowState::default();
    } else {
        assign_if_some(&mut item.workflow, patch.workflow.as_ref());
    }
}

fn apply_planning_patch(target: &mut PlanningState, patch: Option<&PlanningState>) {
    let Some(patch) = patch else {
        return;
    };
    if patch.summary.is_some() {
        target.summary.clone_from(&patch.summary);
        target.approved_by.clone_from(&patch.approved_by);
        target.approved_at.clone_from(&patch.approved_at);
        return;
    }
    if patch.approved_by.is_some() {
        target.approved_by.clone_from(&patch.approved_by);
        target.approved_at.clone_from(&patch.approved_at);
    }
}

fn apply_link_patch(item: &mut TaskBoardItem, patch: TaskBoardItemPatch) {
    apply_optional_patch(&mut item.project_id, patch.project_id);
    apply_optional_patch(&mut item.session_id, patch.session_id);
    apply_optional_patch(&mut item.work_item_id, patch.work_item_id);
}

fn assign_if_some<T: Clone>(target: &mut T, value: Option<&T>) {
    if let Some(value) = value {
        target.clone_from(value);
    }
}

fn assign_copy_if_some<T: Copy>(target: &mut T, value: Option<T>) {
    if let Some(value) = value {
        *target = value;
    }
}

fn apply_optional_patch<T>(target: &mut Option<T>, patch: OptionalFieldPatch<T>) {
    match patch {
        OptionalFieldPatch::Unchanged => {}
        OptionalFieldPatch::Set(value) => *target = Some(value),
        OptionalFieldPatch::Clear => *target = None,
    }
}

fn read_path(path: &Path) -> Result<TaskBoardItem, CliError> {
    let text = io::read_text(path)?;
    let parsed = io::parse_frontmatter::<TaskBoardFrontmatter>(&text, &path.display().to_string())?;
    Ok(parsed.frontmatter.into_item(parsed.body))
}

fn sort_items(items: &mut [TaskBoardItem]) {
    items.sort_by(|left, right| {
        left.status
            .cmp(&right.status)
            .then_with(|| right.priority.cmp(&left.priority))
            .then_with(|| left.created_at.cmp(&right.created_at))
            .then_with(|| left.id.cmp(&right.id))
    });
}

#[cfg(test)]
mod tests;
