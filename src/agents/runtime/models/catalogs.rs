//! Per-runtime model catalog builders. Kept separate from `models/mod.rs` so
//! the enclosing module stays under the source-file line limit.

use super::{EffortKind, RuntimeModel, RuntimeModelCatalog, RuntimeModelTier};

/// Coarse effort levels exposed to the UI for Anthropic- and Google-style
/// thinking-budget models. Order is low → high.
fn thinking_levels() -> Vec<String> {
    ["off", "low", "medium", "high"]
        .iter()
        .map(ToString::to_string)
        .collect()
}

/// Named effort levels accepted by `OpenAI` `reasoning_effort` and the Mistral
/// Magistral reasoning family. Order is low → high.
fn reasoning_levels() -> Vec<String> {
    ["minimal", "low", "medium", "high"]
        .iter()
        .map(ToString::to_string)
        .collect()
}

/// `OpenAI`-style reasoning effort values, no `minimal`. Used for the handful
/// of runtimes that proxy reasoning but skip the `minimal` rung.
fn reasoning_levels_without_minimal() -> Vec<String> {
    ["low", "medium", "high"]
        .iter()
        .map(ToString::to_string)
        .collect()
}

fn thinking(id: &str, display: &str, tier: RuntimeModelTier) -> RuntimeModel {
    RuntimeModel {
        id: id.into(),
        display_name: display.into(),
        tier,
        effort_kind: EffortKind::ThinkingBudget,
        effort_values: thinking_levels(),
    }
}

fn reasoning(id: &str, display: &str, tier: RuntimeModelTier) -> RuntimeModel {
    RuntimeModel {
        id: id.into(),
        display_name: display.into(),
        tier,
        effort_kind: EffortKind::ReasoningEffort,
        effort_values: reasoning_levels(),
    }
}

fn reasoning_no_minimal(id: &str, display: &str, tier: RuntimeModelTier) -> RuntimeModel {
    RuntimeModel {
        id: id.into(),
        display_name: display.into(),
        tier,
        effort_kind: EffortKind::ReasoningEffort,
        effort_values: reasoning_levels_without_minimal(),
    }
}

fn plain(id: &str, display: &str, tier: RuntimeModelTier) -> RuntimeModel {
    RuntimeModel {
        id: id.into(),
        display_name: display.into(),
        tier,
        effort_kind: EffortKind::None,
        effort_values: Vec::new(),
    }
}

pub(super) fn claude_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from platform.claude.com/docs/en/docs/about-claude/models/overview.
    // Every Claude 4.x model supports extended thinking; we expose a coarse
    // off/low/medium/high bucket that maps to budget_tokens in the runtime
    // adapter.
    use RuntimeModelTier::{Balanced, Fast, Max};
    RuntimeModelCatalog {
        runtime: "claude".into(),
        models: vec![
            thinking("claude-haiku-4-5", "Haiku 4.5", Fast),
            thinking("claude-haiku-4-5-20251001", "Haiku 4.5 (2025-10-01)", Fast),
            thinking("claude-sonnet-4-6", "Sonnet 4.6", Balanced),
            thinking("claude-sonnet-4-5", "Sonnet 4.5", Balanced),
            thinking(
                "claude-sonnet-4-5-20250929",
                "Sonnet 4.5 (2025-09-29)",
                Balanced,
            ),
            thinking("claude-opus-4-7", "Opus 4.7", Max),
            thinking("claude-opus-4-6", "Opus 4.6", Max),
            thinking("claude-opus-4-5", "Opus 4.5", Max),
            thinking("claude-opus-4-5-20251101", "Opus 4.5 (2025-11-01)", Max),
            thinking("claude-opus-4-1", "Opus 4.1", Max),
        ],
        default: "claude-sonnet-4-6".into(),
        cheapest_fastest: "claude-haiku-4-5".into(),
    }
}

pub(super) fn codex_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from developers.openai.com/api/docs/models/all.
    // `reasoning_effort` is accepted only by the GPT-5 reasoning family
    // (Codex and Pro variants). Mini/nano chat variants ignore the flag.
    use RuntimeModelTier::{Balanced, Fast, Max};
    RuntimeModelCatalog {
        runtime: "codex".into(),
        models: vec![
            plain("gpt-5.4-nano", "GPT-5.4 nano", Fast),
            plain("gpt-5-nano", "GPT-5 nano", Fast),
            plain("gpt-5.4-mini", "GPT-5.4 mini", Fast),
            plain("gpt-5-mini", "GPT-5 mini", Fast),
            reasoning("gpt-5.1-codex-mini", "GPT-5.1 Codex mini", Fast),
            reasoning("gpt-5.4", "GPT-5.4", Balanced),
            reasoning("gpt-5", "GPT-5", Balanced),
            reasoning("gpt-5-codex", "GPT-5 Codex", Balanced),
            reasoning("gpt-5.4-pro", "GPT-5.4 Pro", Max),
        ],
        default: "gpt-5-codex".into(),
        cheapest_fastest: "gpt-5.1-codex-mini".into(),
    }
}

pub(super) fn gemini_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from ai.google.dev/gemini-api/docs/models.
    // Flash-Lite variants are non-thinking; Pro and Flash support thinking
    // config.
    use RuntimeModelTier::{Balanced, Fast, Max};
    RuntimeModelCatalog {
        runtime: "gemini".into(),
        models: vec![
            plain("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite", Fast),
            plain(
                "gemini-3.1-flash-lite-preview",
                "Gemini 3.1 Flash-Lite (preview)",
                Fast,
            ),
            thinking("gemini-2.5-flash", "Gemini 2.5 Flash", Fast),
            thinking("gemini-3-flash-preview", "Gemini 3 Flash (preview)", Fast),
            thinking("gemini-2.5-pro", "Gemini 2.5 Pro", Balanced),
            thinking("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)", Max),
        ],
        default: "gemini-2.5-pro".into(),
        cheapest_fastest: "gemini-2.5-flash-lite".into(),
    }
}

pub(super) fn copilot_catalog() -> RuntimeModelCatalog {
    // GitHub Copilot proxies multiple providers. Effort-capable models inherit
    // the provider's family: Claude → thinking, OpenAI reasoning → reasoning
    // effort, Gemini thinking → thinking, Flash-Lite none. Copilot passes the
    // effort value through to the underlying provider.
    use RuntimeModelTier::{Balanced, Fast, Max};
    RuntimeModelCatalog {
        runtime: "copilot".into(),
        models: vec![
            plain("gpt-5.4-mini", "GPT-5.4 mini", Fast),
            thinking("claude-haiku-4-5", "Claude Haiku 4.5", Fast),
            thinking("gemini-2.5-flash", "Gemini 2.5 Flash", Fast),
            reasoning("gpt-5.4", "GPT-5.4", Balanced),
            thinking("claude-sonnet-4-6", "Claude Sonnet 4.6", Balanced),
            thinking("gemini-2.5-pro", "Gemini 2.5 Pro", Balanced),
            reasoning("gpt-5.4-pro", "GPT-5.4 Pro", Max),
            thinking("claude-opus-4-7", "Claude Opus 4.7", Max),
        ],
        default: "claude-sonnet-4-6".into(),
        cheapest_fastest: "gpt-5.4-mini".into(),
    }
}

pub(super) fn vibe_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from docs.mistral.ai/getting-started/models/models_overview.
    // Only the Magistral family accepts a reasoning effort parameter; standard
    // Mistral chat and coding models ignore it.
    use RuntimeModelTier::{Balanced, Fast, Max};
    RuntimeModelCatalog {
        runtime: "vibe".into(),
        models: vec![
            plain("mistral-small-4-0-26-03", "Mistral Small 4", Fast),
            plain("mistral-small-3-2-25-06", "Mistral Small 3.2", Fast),
            plain("codestral-25-08", "Codestral", Fast),
            plain("devstral-2-25-12", "Devstral 2", Fast),
            plain("mistral-medium-3-1-25-08", "Mistral Medium 3.1", Balanced),
            plain("mistral-large-3-25-12", "Mistral Large 3", Balanced),
            reasoning_no_minimal("magistral-small-1-2-25-09", "Magistral Small 1.2", Max),
            reasoning_no_minimal("magistral-medium-1-2-25-09", "Magistral Medium 1.2", Max),
        ],
        default: "mistral-large-3-25-12".into(),
        cheapest_fastest: "mistral-small-4-0-26-03".into(),
    }
}

pub(super) fn opencode_catalog() -> RuntimeModelCatalog {
    // OpenCode is provider-agnostic. Effort support matches the underlying
    // provider family (`anthropic/*` → thinking, `openai/*` reasoning →
    // reasoning effort, `google/*` thinking variants → thinking, etc.).
    use RuntimeModelTier::{Balanced, Fast, Max};
    RuntimeModelCatalog {
        runtime: "opencode".into(),
        models: vec![
            thinking("anthropic/claude-haiku-4-5", "Claude Haiku 4.5", Fast),
            plain("openai/gpt-5.4-mini", "GPT-5.4 mini", Fast),
            reasoning("openai/gpt-5.1-codex-mini", "GPT-5.1 Codex mini", Fast),
            thinking("google/gemini-2.5-flash", "Gemini 2.5 Flash", Fast),
            plain("mistral/mistral-small-4-0-26-03", "Mistral Small 4", Fast),
            thinking("anthropic/claude-sonnet-4-6", "Claude Sonnet 4.6", Balanced),
            reasoning("openai/gpt-5.4", "GPT-5.4", Balanced),
            reasoning("openai/gpt-5-codex", "GPT-5 Codex", Balanced),
            thinking("google/gemini-2.5-pro", "Gemini 2.5 Pro", Balanced),
            thinking("anthropic/claude-opus-4-7", "Claude Opus 4.7", Max),
            reasoning("openai/gpt-5.4-pro", "GPT-5.4 Pro", Max),
            thinking(
                "google/gemini-3.1-pro-preview",
                "Gemini 3.1 Pro (preview)",
                Max,
            ),
        ],
        default: "anthropic/claude-sonnet-4-6".into(),
        cheapest_fastest: "anthropic/claude-haiku-4-5".into(),
    }
}
