use std::path::{Path, PathBuf};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io;
#[cfg(test)]
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::workspace::harness_data_root;
#[cfg(test)]
use crate::workspace::utc_now;

mod frontmatter;
#[cfg(test)]
mod loading;
#[cfg(test)]
mod parse_cache;
use frontmatter::TaskBoardFrontmatter;
#[cfg(test)]
use parse_cache::BOARD_PARSE_CACHE;

use super::TaskBoardWorkflowKind;
#[cfg(test)]
use super::types::CURRENT_TASK_BOARD_ITEM_VERSION;
use super::types::{
    AgentMode, ExternalRef, PlanningState, TaskBoardItem, TaskBoardItemKind, TaskBoardPriority,
    TaskBoardStatus, TaskBoardWorkflowState,
};

#[derive(Debug, Clone)]
#[cfg(test)]
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
    pub kind: Option<TaskBoardItemKind>,
    pub project_id: OptionalFieldPatch<String>,
    pub target_project_types: Option<Vec<String>>,
    pub agent_mode: Option<AgentMode>,
    pub workflow_kind: Option<TaskBoardWorkflowKind>,
    pub execution_repository: OptionalFieldPatch<String>,
    pub estimated_tokens: OptionalFieldPatch<u64>,
    pub estimated_cost_microusd: OptionalFieldPatch<u64>,
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
    pub parent_item_id: OptionalFieldPatch<String>,
}

#[derive(Debug, Clone, Default)]
pub enum OptionalFieldPatch<T> {
    #[default]
    Unchanged,
    Set(T),
    Clear,
}

#[must_use]
pub(crate) fn default_board_root() -> PathBuf {
    harness_data_root().join("task-board")
}

#[cfg(test)]
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
        self.with_mutation_lock(|| {
            item.title = title.to_string();
            item.body = body.to_string();
            apply_canonical_persisted_status(&mut item);
            self.validate_new_id(&item.id)?;
            self.save(&item)?;
            Ok(item)
        })
    }

    /// List active board items, optionally filtered by status.
    ///
    /// # Errors
    /// Returns `CliError` if the tasks directory cannot be read or an item
    /// cannot be parsed or repaired on disk.
    pub fn list(&self, status: Option<TaskBoardStatus>) -> Result<Vec<TaskBoardItem>, CliError> {
        let status = status.map(TaskBoardStatus::canonical_persisted_status);
        let mut items = self.read_all_items()?;
        items
            .retain(|item| !item.is_deleted() && status.is_none_or(|target| item.status == target));
        sort_items(&mut items);
        Ok(items)
    }

    /// List every board item on disk including tombstoned ones.
    ///
    /// # Errors
    /// Returns `CliError` if the tasks directory cannot be read or an item
    /// cannot be parsed.
    pub fn list_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut items = self.read_all_items()?;
        sort_items(&mut items);
        Ok(items)
    }

    /// Patch one board item in place.
    ///
    /// # Errors
    /// Returns `CliError` if the item cannot be loaded or saved.
    pub fn update(&self, id: &str, patch: TaskBoardItemPatch) -> Result<TaskBoardItem, CliError> {
        self.with_mutation_lock(|| self.update_unlocked(id, patch))
    }
    /// Conditionally patch one board item from its latest persisted value.
    ///
    /// The decision and write share the board mutation lock, so a derived
    /// update cannot overwrite a user edit made after an earlier list/get.
    ///
    /// # Errors
    /// Returns `CliError` if the item cannot be loaded, locked, or saved.
    #[cfg(test)]
    pub(crate) fn update_if(
        &self,
        id: &str,
        patch_for: impl FnOnce(&TaskBoardItem) -> Option<TaskBoardItemPatch>,
    ) -> Result<Option<TaskBoardItem>, CliError> {
        self.with_mutation_lock(|| {
            let item = self.get_locked(id)?;
            let Some(patch) = patch_for(&item) else {
                return Ok(None);
            };
            self.update_item(item, patch).map(Some)
        })
    }
    /// Tombstone one board item.
    ///
    /// # Errors
    /// Returns `CliError` if the item cannot be loaded or saved.
    pub fn delete(&self, id: &str) -> Result<TaskBoardItem, CliError> {
        self.with_mutation_lock(|| {
            let mut item = self.get_locked(id)?;
            apply_canonical_persisted_status(&mut item);
            let now = utc_now();
            item.deleted_at = Some(now.clone());
            item.updated_at = now;
            self.save(&item)?;
            Ok(item)
        })
    }

    fn update_unlocked(
        &self,
        id: &str,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        let item = self.get_locked(id)?;
        self.update_item(item, patch)
    }

    fn update_item(
        &self,
        mut item: TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError> {
        apply_patch(&mut item, patch);
        apply_canonical_persisted_status(&mut item);
        item.updated_at = utc_now();
        self.save(&item)?;
        Ok(item)
    }

    fn with_mutation_lock<T>(
        &self,
        action: impl FnOnce() -> Result<T, CliError>,
    ) -> Result<T, CliError> {
        with_exclusive_flock(
            &self.root.join(".mutation.lock"),
            FlockErrorContext::new("task board persistence"),
            action,
        )
    }

    fn save(&self, item: &TaskBoardItem) -> Result<(), CliError> {
        let path = self.path_for(&item.id)?;
        Self::save_to_path(&path, item)
    }

    fn save_to_path(path: &Path, item: &TaskBoardItem) -> Result<(), CliError> {
        if item.schema_version != CURRENT_TASK_BOARD_ITEM_VERSION {
            return Err(CliErrorKind::workflow_version(format!(
                "task-board item '{}' uses unsupported schema v{}",
                item.id, item.schema_version
            ))
            .into());
        }
        let frontmatter = TaskBoardFrontmatter::from(item);
        let yaml = serde_yml::to_string(&frontmatter).map_err(|error| {
            CliErrorKind::workflow_serialize(format!("serialize task-board item: {error}"))
        })?;
        // serde_yml does not guarantee a trailing newline, so anchor the closing
        // fence on its own line rather than gluing it onto the last YAML value.
        io::write_text(
            path,
            &format!("---\n{}\n---\n\n{}", yaml.trim_end(), item.body),
        )?;
        BOARD_PARSE_CACHE.forget(path);
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

    fn repair_legacy_status_at_locked(
        path: &Path,
        item: &mut TaskBoardItem,
    ) -> Result<(), CliError> {
        if apply_canonical_persisted_status(item) {
            Self::save_to_path(path, item)?;
        }
        Ok(())
    }
}

pub(crate) fn validate_loaded_id(expected: &str, item: &TaskBoardItem) -> Result<(), CliError> {
    if item.id == expected {
        return Ok(());
    }
    Err(CliErrorKind::workflow_parse(format!(
        "task-board item file id mismatch: expected '{expected}', found '{}'",
        item.id
    ))
    .into())
}

pub(crate) fn apply_canonical_persisted_status(item: &mut TaskBoardItem) -> bool {
    let status = item.status.canonical_persisted_status();
    if item.status == status {
        return false;
    }
    item.status = status;
    true
}

pub(crate) fn apply_patch(item: &mut TaskBoardItem, patch: TaskBoardItemPatch) {
    apply_core_patch(item, &patch);
    apply_link_patch(item, patch);
}

fn apply_core_patch(item: &mut TaskBoardItem, patch: &TaskBoardItemPatch) {
    assign_if_some(&mut item.title, patch.title.as_ref());
    assign_if_some(&mut item.body, patch.body.as_ref());
    assign_copy_if_some(&mut item.status, patch.status);
    assign_copy_if_some(&mut item.priority, patch.priority);
    assign_copy_if_some(&mut item.agent_mode, patch.agent_mode);
    assign_copy_if_some(&mut item.workflow_kind, patch.workflow_kind);
    assign_if_some(&mut item.tags, patch.tags.as_ref());
    assign_if_some(&mut item.kind, patch.kind.as_ref());
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
    apply_optional_patch(&mut item.execution_repository, patch.execution_repository);
    apply_optional_patch(&mut item.estimated_tokens, patch.estimated_tokens);
    apply_optional_patch(
        &mut item.estimated_cost_microusd,
        patch.estimated_cost_microusd,
    );
    apply_optional_patch(&mut item.session_id, patch.session_id);
    apply_optional_patch(&mut item.work_item_id, patch.work_item_id);
    apply_optional_patch(&mut item.parent_item_id, patch.parent_item_id);
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

pub(crate) fn read_path(path: &Path) -> Result<TaskBoardItem, CliError> {
    let text = io::read_text(path)?;
    let label = path.display().to_string();
    let parsed = io::parse_frontmatter::<serde_json::Value>(&text, &label)?;
    let mut document = parsed.frontmatter;
    normalize_legacy_umbrella_statuses(&mut document);
    let frontmatter: TaskBoardFrontmatter = serde_json::from_value(document)
        .map_err(|error| CliErrorKind::workflow_parse(format!("{label} frontmatter: {error}")))?;
    Ok(frontmatter.into_item(parsed.body))
}

fn normalize_legacy_umbrella_statuses(document: &mut serde_json::Value) {
    let Some(frontmatter) = document.as_object_mut() else {
        return;
    };
    if let Some(status) = frontmatter.get_mut("status") {
        normalize_legacy_status(status);
    }
    let Some(external_refs) = frontmatter
        .get_mut("external_refs")
        .and_then(serde_json::Value::as_array_mut)
    else {
        return;
    };
    for external_ref in external_refs {
        let Some(sync_state) = external_ref
            .as_object_mut()
            .and_then(|mapping| mapping.get_mut("sync_state"))
            .and_then(serde_json::Value::as_object_mut)
        else {
            continue;
        };
        if let Some(status) = sync_state.get_mut("status") {
            normalize_legacy_status(status);
        }
    }
}

fn normalize_legacy_status(value: &mut serde_json::Value) {
    if value.as_str() == Some("umbrella") {
        *value = serde_json::Value::String("backlog".to_string());
    }
}

#[cfg(test)]
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
