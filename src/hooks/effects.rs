use crate::errors::CliError;
use crate::hook_payloads::HookContext;
use crate::workflow::runner::{self as runner_wf, RunnerWorkflowState};

pub(crate) fn persist_runner_state(
    ctx: &HookContext,
    state: &RunnerWorkflowState,
) -> Result<bool, CliError> {
    let Some(run_dir) = ctx.effective_run_dir() else {
        return Ok(false);
    };
    runner_wf::write_runner_state(&run_dir, state)?;
    Ok(true)
}

pub(crate) fn transition_runner_state<F>(
    ctx: &HookContext,
    update: F,
) -> Result<Option<RunnerWorkflowState>, CliError>
where
    F: FnOnce(&RunnerWorkflowState) -> Option<RunnerWorkflowState>,
{
    let Some(current) = ctx.runner_state.as_ref() else {
        return Ok(None);
    };
    let Some(next) = update(current) else {
        return Ok(None);
    };
    persist_runner_state(ctx, &next)?;
    Ok(Some(next))
}
