use crate::hooks::application::GuardContext;
use crate::kernel::tooling::ToolCategory;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ToolDispatch {
    Question,
    Write,
    Command,
    Other,
}

pub(crate) fn classify_tool_interaction(ctx: &GuardContext) -> ToolDispatch {
    if !ctx.question_prompts().is_empty() || !ctx.question_answers().is_empty() {
        return ToolDispatch::Question;
    }

    if matches!(
        ctx.tool.as_ref().map(|tool| &tool.category),
        Some(ToolCategory::FileWrite | ToolCategory::FileEdit)
    ) || !ctx.write_paths().is_empty()
    {
        return ToolDispatch::Write;
    }

    if matches!(
        ctx.tool.as_ref().map(|tool| &tool.category),
        Some(ToolCategory::Shell)
    ) || ctx.command_text().is_some()
    {
        return ToolDispatch::Command;
    }

    ToolDispatch::Other
}
