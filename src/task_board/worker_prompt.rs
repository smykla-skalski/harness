use std::collections::BTreeMap;
use std::fmt::Write as _;

use crate::errors::CliError;

use super::prompt_catalog::{PromptId, render_prompt};
use super::{ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardStatus};

pub(crate) const DISPATCH_PLACEHOLDER: &str = "<assigned-at-dispatch>";

pub(crate) struct WorkerPromptContext<'a> {
    pub(crate) board_item_id: &'a str,
    pub(crate) work_item_id: &'a str,
    pub(crate) worktree: Option<&'a str>,
    pub(crate) session_id: Option<&'a str>,
    pub(crate) managed_run_id: Option<&'a str>,
    pub(crate) status: TaskBoardStatus,
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
pub(crate) fn render_worker_prompt(
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
            lifecycle_section(context.session_id, context.work_item_id),
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

fn lifecycle_section(session_id: Option<&str>, work_item_id: &str) -> String {
    let mut section = String::from(
        "\n\nLifecycle:\nImplement the requested work, keep changes scoped, and run the smallest relevant validation.",
    );
    let Some(session_id) = session_id else {
        section.push_str(" Submit the task for review when ready.");
        return section;
    };
    write!(
        section,
        "\n1. Run `harness session task list {session_id} --json` and read `assigned_to` from task `{work_item_id}`; use that value as `<assigned-agent-id>`.\n2. Report progress with `harness session task checkpoint {session_id} {work_item_id} --actor <assigned-agent-id> --summary \"<summary>\" --progress <0-100>`.\n3. Submit with `harness session task submit-for-review {session_id} {work_item_id} --actor <assigned-agent-id> --summary \"<summary>\"`.\nThe controller also advances this task when the managed run completes and is the authoritative safety net."
    )
    .expect("writing to a string cannot fail");
    section
}

/// The prompt shown in a dispatch preview. Previews are informational and the
/// spawn re-renders independently, so a prompt that cannot be rendered for
/// this item shows the reason rather than substituting text no agent will run.
#[must_use]
pub(crate) fn plan_worker_prompt(item: &TaskBoardItem) -> String {
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

fn render_external_refs(references: &[ExternalRef]) -> Option<String> {
    (!references.is_empty()).then(|| {
        references
            .iter()
            .map(|reference| {
                let provider = match reference.provider {
                    ExternalRefProvider::GitHub => "github",
                    ExternalRefProvider::Todoist => "todoist",
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
