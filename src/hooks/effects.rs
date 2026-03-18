use crate::audit_log::{AuditAppendRequest, append_audit_entry};
use crate::errors::CliError;
use crate::hooks::context::GuardContext;
use crate::hooks::result::NormalizedHookResult;
use crate::workflow::runner::{self as runner_wf, RunnerWorkflowState};

/// Explicit side effects emitted by hook handlers and applied by the engine.
#[derive(Debug, Clone)]
pub enum HookEffect {
    WriteRunnerState(RunnerWorkflowState),
    AppendAudit {
        request: AuditAppendRequest,
        warn_only: bool,
    },
}

/// Full hook outcome: decision plus explicit side effects.
#[derive(Debug, Clone)]
pub struct HookOutcome {
    pub result: NormalizedHookResult,
    pub effects: Vec<HookEffect>,
}

impl HookOutcome {
    #[must_use]
    pub fn allow() -> Self {
        Self {
            result: NormalizedHookResult::allow(),
            effects: Vec::new(),
        }
    }

    #[must_use]
    pub fn from_hook_result(result: crate::hook::HookResult) -> Self {
        Self {
            result: NormalizedHookResult::from_hook_result(result),
            effects: Vec::new(),
        }
    }

    #[must_use]
    pub fn with_effect(mut self, effect: HookEffect) -> Self {
        self.effects.push(effect);
        self
    }

    #[must_use]
    pub fn with_result(mut self, result: NormalizedHookResult) -> Self {
        self.result = result;
        self
    }
}

pub(crate) fn persist_runner_state(
    ctx: &GuardContext,
    state: &RunnerWorkflowState,
) -> Result<bool, CliError> {
    let Some(run_dir) = ctx.effective_run_dir() else {
        return Ok(false);
    };
    runner_wf::write_runner_state(run_dir.as_ref(), state)?;
    Ok(true)
}

pub(crate) fn transition_runner_state<F>(
    ctx: &GuardContext,
    update: F,
) -> Result<Option<HookEffect>, CliError>
where
    F: FnOnce(&RunnerWorkflowState) -> Option<RunnerWorkflowState>,
{
    let Some(current) = ctx.runner_state.as_ref() else {
        return Ok(None);
    };
    Ok(update(current).map(HookEffect::WriteRunnerState))
}

pub(crate) fn apply_effects(
    ctx: &GuardContext,
    result: &mut NormalizedHookResult,
    effects: &[HookEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            HookEffect::WriteRunnerState(state) => {
                let _ = persist_runner_state(ctx, state)?;
            }
            HookEffect::AppendAudit { request, warn_only } => {
                if let Err(error) = append_audit_entry(request.clone()) {
                    if *warn_only {
                        *result = NormalizedHookResult::warn(
                            "KSR006",
                            format!("audit log write failed: {error}"),
                        );
                        continue;
                    }
                    return Err(error);
                }
            }
        }
    }
    Ok(())
}
