use crate::errors::CliError;
use crate::hooks::protocol::context::GuardContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::run::audit::{AuditAppendRequest, append_audit_entry};
use crate::run::workflow::{self as runner_wf, RunnerWorkflowState};

/// Explicit side effects emitted by hook handlers and applied by the engine.
#[derive(Debug, Clone)]
pub enum HookEffect {
    Decide(NormalizedHookResult),
    WriteRunnerState {
        expected_transition_count: u32,
        state: RunnerWorkflowState,
    },
    AppendAudit(AuditAppendRequest),
    InjectContext(String),
}

/// Full hook outcome: ordered explicit effects emitted by a hook.
#[derive(Debug, Clone)]
pub struct HookOutcome {
    effects: Vec<HookEffect>,
}

impl HookOutcome {
    #[must_use]
    pub fn allow() -> Self {
        Self::decide(NormalizedHookResult::allow())
    }

    #[must_use]
    pub fn decide(result: NormalizedHookResult) -> Self {
        Self {
            effects: vec![HookEffect::Decide(result)],
        }
    }

    #[must_use]
    pub fn from_hook_result(result: HookResult) -> Self {
        Self::decide(NormalizedHookResult::from_hook_result(result))
    }

    #[must_use]
    pub fn with_effect(mut self, effect: HookEffect) -> Self {
        self.effects.push(effect);
        self
    }

    #[must_use]
    pub fn effects(&self) -> &[HookEffect] {
        &self.effects
    }

    /// # Panics
    /// Panics when the outcome contains no `Decide` effect.
    #[must_use]
    pub fn decision(&self) -> &NormalizedHookResult {
        self.effects
            .iter()
            .find_map(|effect| match effect {
                HookEffect::Decide(result) => Some(result),
                HookEffect::WriteRunnerState { .. }
                | HookEffect::AppendAudit(_)
                | HookEffect::InjectContext(_) => None,
            })
            .expect("hook outcomes must include a Decide effect")
    }

    pub fn state_transitions(&self) -> impl Iterator<Item = &RunnerWorkflowState> {
        self.effects.iter().filter_map(|effect| match effect {
            HookEffect::WriteRunnerState { state, .. } => Some(state),
            HookEffect::Decide(_) | HookEffect::AppendAudit(_) | HookEffect::InjectContext(_) => {
                None
            }
        })
    }

    pub fn audit_entries(&self) -> impl Iterator<Item = &AuditAppendRequest> {
        self.effects.iter().filter_map(|effect| match effect {
            HookEffect::AppendAudit(request) => Some(request),
            HookEffect::Decide(_)
            | HookEffect::WriteRunnerState { .. }
            | HookEffect::InjectContext(_) => None,
        })
    }

    pub fn injected_contexts(&self) -> impl Iterator<Item = &str> {
        self.effects.iter().filter_map(|effect| match effect {
            HookEffect::InjectContext(text) => Some(text.as_str()),
            HookEffect::Decide(_)
            | HookEffect::WriteRunnerState { .. }
            | HookEffect::AppendAudit(_) => None,
        })
    }

    #[must_use]
    pub fn normalized_result(&self) -> NormalizedHookResult {
        let mut result = self.decision().clone();
        let injected = self.injected_contexts().collect::<Vec<_>>();
        if !injected.is_empty() {
            let joined = injected.join("\n\n");
            result.additional_context = Some(match result.additional_context.take() {
                Some(existing) if !existing.is_empty() => format!("{existing}\n\n{joined}"),
                Some(_) | None => joined,
            });
        }
        result
    }

    #[must_use]
    pub fn to_hook_result(&self) -> HookResult {
        self.normalized_result().to_hook_result()
    }
}

pub(crate) fn persist_runner_state(
    ctx: &GuardContext,
    expected_transition_count: u32,
    state: &RunnerWorkflowState,
) -> Result<bool, CliError> {
    let Some(run_dir) = ctx.effective_run_dir() else {
        return Ok(false);
    };
    runner_wf::write_runner_state_if_current(run_dir.as_ref(), expected_transition_count, state)?;
    Ok(true)
}

pub(crate) fn transition_runner_state<F>(ctx: &GuardContext, update: F) -> Option<HookEffect>
where
    F: FnOnce(&RunnerWorkflowState) -> Option<RunnerWorkflowState>,
{
    let current = ctx.runner_state.as_ref()?;
    update(current).map(|state| HookEffect::WriteRunnerState {
        expected_transition_count: current.transition_count,
        state,
    })
}

pub(crate) fn apply_effects(
    ctx: &GuardContext,
    result: &mut NormalizedHookResult,
    effects: &[HookEffect],
) -> Result<(), CliError> {
    for effect in effects {
        match effect {
            HookEffect::Decide(_) | HookEffect::InjectContext(_) => {}
            HookEffect::WriteRunnerState {
                expected_transition_count,
                state,
            } => {
                let _ = persist_runner_state(ctx, *expected_transition_count, state)?;
            }
            HookEffect::AppendAudit(request) => {
                if let Err(error) = append_audit_entry(request.clone()) {
                    *result = NormalizedHookResult::warn(
                        "KSR006",
                        format!("audit log write failed: {error}"),
                    );
                }
            }
        }
    }
    Ok(())
}
