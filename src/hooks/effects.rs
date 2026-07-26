use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::protocol::result::NormalizedHookResult;

/// Explicit side effects emitted by hook handlers and applied by the engine.
#[derive(Debug, Clone)]
pub enum HookEffect {
    Decide(NormalizedHookResult),
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

    /// # Panics
    /// Panics when the outcome contains no `Decide` effect.
    #[must_use]
    pub fn decision(&self) -> &NormalizedHookResult {
        self.effects
            .iter()
            .find_map(|effect| match effect {
                HookEffect::Decide(result) => Some(result),
                HookEffect::InjectContext(_) => None,
            })
            .expect("hook outcomes must include a Decide effect")
    }

    pub fn injected_contexts(&self) -> impl Iterator<Item = &str> {
        self.effects.iter().filter_map(|effect| match effect {
            HookEffect::InjectContext(text) => Some(text.as_str()),
            HookEffect::Decide(_) => None,
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
