use std::collections::BTreeMap;
use std::fmt::Write as _;

use harness_kernel::errors::CliError;

use super::prompt_catalog::{PromptId, render_prompt};
use super::{
    AgentMode, DispatchAppliedTask, ExternalRef, ExternalRefProvider, TaskBoardItem,
    TaskBoardStatus,
};

pub(crate) const DISPATCH_PLACEHOLDER: &str = "<assigned-at-dispatch>";

pub struct WorkerPromptContext<'a> {
    pub board_item_id: &'a str,
    pub work_item_id: &'a str,
    pub worktree: Option<&'a str>,
    pub session_id: Option<&'a str>,
    pub managed_run_id: Option<&'a str>,
    pub status: TaskBoardStatus,
}

/// Render the worker prompt for one item from the active prompt catalog.
///
/// Each optional fact contributes two variables: `<name>_section`, always
/// present and empty when the fact is missing, which is what lets one fixed
/// template reproduce the shipped prompt; and the raw `<name>`, present only
/// when the item has it, so a custom template naming it fails for an item that
/// does not.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item, so the caller refuses the spawn rather than starting an agent with a
/// prompt it could not complete.
pub fn render_worker_prompt(
    item: &TaskBoardItem,
    context: &WorkerPromptContext<'_>,
) -> Result<String, CliError> {
    let mut variables: BTreeMap<&'static str, String> = BTreeMap::from([
        ("title", item.title.clone()),
        ("board_item_id", context.board_item_id.to_string()),
        ("work_item_id", context.work_item_id.to_string()),
        ("priority", format!("{:?}", item.priority)),
        ("status", format!("{:?}", context.status)),
        (
            "lifecycle_section",
            lifecycle_section(context.session_id, context.board_item_id),
        ),
    ]);
    for fact in optional_facts(item, context) {
        fact.push_into(&mut variables);
    }
    render_prompt(PromptId::Worker, &variables)
}

/// Every optional fact, in the order the shipped prompt lists its sections.
///
/// Kept as one function so the byte goldens can walk the same set the renderer
/// does, instead of a second list that goes stale the next time a fact lands.
fn optional_facts(item: &TaskBoardItem, context: &WorkerPromptContext<'_>) -> [Fact; 8] {
    [
        Fact::new(
            "project_id",
            "project_id_section",
            "Project",
            item.project_id.clone(),
        ),
        Fact::new(
            "worktree",
            "worktree_section",
            "Worktree",
            context.worktree.map(str::to_owned),
        ),
        Fact::new(
            "session_id",
            "session_id_section",
            "Session id",
            context.session_id.map(str::to_owned),
        ),
        Fact::new(
            "managed_run_id",
            "managed_run_id_section",
            "Managed run id",
            context.managed_run_id.map(str::to_owned),
        ),
        Fact::new(
            "tags",
            "tags_section",
            "Tags",
            (!item.tags.is_empty()).then(|| item.tags.join(", ")),
        ),
        Fact::new(
            "external_refs",
            "external_refs_section",
            "External refs",
            render_external_refs(&item.external_refs),
        ),
        Fact::new(
            "planning_summary",
            "planning_summary_section",
            "Planning summary",
            item.planning.summary.clone(),
        ),
        Fact::new(
            "task_body",
            "task_body_section",
            "Task body",
            non_empty(item.body.as_str()).map(str::to_owned),
        ),
    ]
}

/// One optional item fact and the section the shipped prompt wrapped it in.
struct Fact {
    name: &'static str,
    section_name: &'static str,
    section_title: &'static str,
    value: Option<String>,
}

impl Fact {
    fn new(
        name: &'static str,
        section_name: &'static str,
        section_title: &'static str,
        value: Option<String>,
    ) -> Self {
        Self {
            name,
            section_name,
            section_title,
            value,
        }
    }

    fn push_into(self, variables: &mut BTreeMap<&'static str, String>) {
        let Some(value) = self.value else {
            variables.insert(self.section_name, String::new());
            return;
        };
        variables.insert(
            self.section_name,
            format!("\n\n{}:\n{value}", self.section_title),
        );
        variables.insert(self.name, value);
    }
}

/// Every worker reports against its board item, whether or not a legacy Session
/// still owns it: the board is the one durable record either way, and a Session
/// task that exists is translated into the same record by evaluation.
fn lifecycle_section(_session_id: Option<&str>, board_item_id: &str) -> String {
    let mut section = String::from(
        "\n\nLifecycle:\nImplement the requested work, keep changes scoped, and run the smallest relevant validation.",
    );
    write!(
        section,
        "\n1. Report progress with `harness task-board progress checkpoint --item-id {board_item_id} --summary \"<summary>\" --progress <0-100>`.\n2. Submit with `harness task-board progress submit-for-review --item-id {board_item_id} --summary \"<summary>\"`.\n3. If the work cannot continue, run `harness task-board progress block --item-id {board_item_id} --reason \"<reason>\"` instead of stopping silently.\nRead the record back at any time with `harness task-board progress show --item-id {board_item_id}`. The controller also settles this item when the managed run completes and is the authoritative safety net."
    )
    .expect("writing to a string cannot fail");
    section
}

/// The prompt shown in a dispatch preview. Previews are informational and the
/// spawn re-renders independently, so a prompt that cannot be rendered for
/// this item shows the reason rather than substituting text no agent will run.
#[must_use]
pub fn plan_worker_prompt(item: &TaskBoardItem) -> String {
    render_worker_prompt(
        item,
        &WorkerPromptContext {
            board_item_id: item.id.as_str(),
            work_item_id: DISPATCH_PLACEHOLDER,
            worktree: item
                .workflow
                .worktree
                .as_deref()
                .or(Some(DISPATCH_PLACEHOLDER)),
            session_id: item.session_id.as_deref().or(Some(DISPATCH_PLACEHOLDER)),
            managed_run_id: Some(DISPATCH_PLACEHOLDER),
            status: TaskBoardStatus::InProgress,
        },
    )
    .unwrap_or_else(|error| error.message())
}

#[must_use]
pub fn codex_worker_id(dispatch_intent_id: &str) -> String {
    format!("codex-{dispatch_intent_id}")
}

#[must_use]
pub fn terminal_worker_id(dispatch_intent_id: &str) -> String {
    format!("agent-tui-{dispatch_intent_id}")
}

#[must_use]
pub fn managed_worker_id(applied: &DispatchAppliedTask, dispatch_intent_id: &str) -> String {
    if applied.item.agent_mode == AgentMode::Interactive {
        terminal_worker_id(dispatch_intent_id)
    } else {
        codex_worker_id(dispatch_intent_id)
    }
}

/// Render the ordinary worker prompt for one dispatched item.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item.
pub fn worker_prompt(
    applied: &DispatchAppliedTask,
    managed_run_id: &str,
) -> Result<String, CliError> {
    render_worker_prompt(
        &applied.item,
        &WorkerPromptContext {
            board_item_id: &applied.board_item_id,
            work_item_id: &applied.work_item_id,
            worktree: applied.item.workflow.worktree.as_deref(),
            session_id: applied.session_id.as_deref(),
            managed_run_id: Some(managed_run_id),
            status: applied.item.status,
        },
    )
}

/// The prompt this dispatch will start its worker with, rendered the same way
/// the start path renders it.
///
/// # Errors
/// Returns an error when the configured prompt cannot be rendered for this
/// item.
pub fn rendered_worker_prompt(
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<String, CliError> {
    let managed_run_id = managed_worker_id(applied, dispatch_intent_id);
    worker_prompt(applied, &managed_run_id)
}

fn render_external_refs(references: &[ExternalRef]) -> Option<String> {
    (!references.is_empty()).then(|| {
        references
            .iter()
            .map(|reference| {
                let provider = match reference.provider {
                    ExternalRefProvider::GitHub => "github",
                };
                reference.url.as_ref().map_or_else(
                    || format!("{provider}:{}", reference.external_id),
                    |url| format!("{provider}:{} ({url})", reference.external_id),
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    })
}

fn non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

#[cfg(test)]
#[path = "worker_prompt_tests.rs"]
mod tests;
