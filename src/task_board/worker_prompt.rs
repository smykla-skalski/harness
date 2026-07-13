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

pub(crate) fn render_worker_prompt(
    item: &TaskBoardItem,
    context: &WorkerPromptContext<'_>,
) -> String {
    let mut prompt = format!(
        "Work on task-board item '{}'.\n\nBoard item: {}\nSession task: {}\nPriority: {:?}\nStatus: {:?}",
        item.title, context.board_item_id, context.work_item_id, item.priority, context.status
    );
    push_optional_section(&mut prompt, "Project", item.project_id.as_deref());
    push_optional_section(&mut prompt, "Worktree", context.worktree);
    push_optional_section(&mut prompt, "Session id", context.session_id);
    push_optional_section(&mut prompt, "Managed run id", context.managed_run_id);
    let tags = (!item.tags.is_empty()).then(|| item.tags.join(", "));
    push_optional_section(&mut prompt, "Tags", tags.as_deref());
    let external_refs = render_external_refs(&item.external_refs);
    push_optional_section(&mut prompt, "External refs", external_refs.as_deref());
    push_optional_section(
        &mut prompt,
        "Planning summary",
        item.planning.summary.as_deref(),
    );
    push_optional_section(&mut prompt, "Task body", non_empty(item.body.as_str()));
    push_lifecycle(&mut prompt, context.session_id, context.work_item_id);
    prompt
}

fn push_lifecycle(prompt: &mut String, session_id: Option<&str>, work_item_id: &str) {
    prompt.push_str(
        "\n\nLifecycle:\nImplement the requested work, keep changes scoped, and run the smallest relevant validation.",
    );
    let Some(session_id) = session_id else {
        prompt.push_str(" Submit the task for review when ready.");
        return;
    };
    prompt.push_str(&format!(
        "\n1. Run `harness session task list {session_id} --json` and read `assigned_to` from task `{work_item_id}`; use that value as `<assigned-agent-id>`.\n2. Report progress with `harness session task checkpoint {session_id} {work_item_id} --actor <assigned-agent-id> --summary \"<summary>\" --progress <0-100>`.\n3. Submit with `harness session task submit-for-review {session_id} {work_item_id} --actor <assigned-agent-id> --summary \"<summary>\"`.\nThe controller also advances this task when the managed run completes and is the authoritative safety net."
    ));
}

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

fn push_optional_section(prompt: &mut String, title: &str, value: Option<&str>) {
    let Some(value) = value else {
        return;
    };
    prompt.push_str("\n\n");
    prompt.push_str(title);
    prompt.push_str(":\n");
    prompt.push_str(value);
}

fn non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::TaskBoardItem;

    #[test]
    fn plan_prompt_preserves_existing_session_checkout_and_marks_reserved_ids() {
        let mut item = TaskBoardItem::new(
            "board-1".into(),
            "Existing session task".into(),
            "Implement it".into(),
            "2026-07-13T00:00:00Z".into(),
        );
        item.session_id = Some("session-existing".into());
        item.workflow.worktree = Some("/tmp/existing-worktree".into());

        let prompt = plan_worker_prompt(&item);

        assert!(prompt.contains("Session id:\nsession-existing"));
        assert!(prompt.contains("Worktree:\n/tmp/existing-worktree"));
        assert!(prompt.contains("Session task: <assigned-at-dispatch>"));
        assert!(prompt.contains("Managed run id:\n<assigned-at-dispatch>"));
    }
}
