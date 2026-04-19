//! Per-runtime model catalog builders. Kept separate from `models/mod.rs` so
//! the enclosing module stays under the source-file line limit.

use super::{RuntimeModel, RuntimeModelCatalog, RuntimeModelTier};

pub(super) fn claude_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from platform.claude.com/docs/en/docs/about-claude/models/overview.
    // Each family ships an alias plus a dated snapshot; we expose both so users
    // can pin to a specific snapshot when needed.
    RuntimeModelCatalog {
        runtime: "claude".into(),
        models: vec![
            // Fast tier
            RuntimeModel {
                id: "claude-haiku-4-5".into(),
                display_name: "Haiku 4.5".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "claude-haiku-4-5-20251001".into(),
                display_name: "Haiku 4.5 (2025-10-01)".into(),
                tier: RuntimeModelTier::Fast,
            },
            // Balanced tier
            RuntimeModel {
                id: "claude-sonnet-4-6".into(),
                display_name: "Sonnet 4.6".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "claude-sonnet-4-5".into(),
                display_name: "Sonnet 4.5".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "claude-sonnet-4-5-20250929".into(),
                display_name: "Sonnet 4.5 (2025-09-29)".into(),
                tier: RuntimeModelTier::Balanced,
            },
            // Max tier
            RuntimeModel {
                id: "claude-opus-4-7".into(),
                display_name: "Opus 4.7".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "claude-opus-4-6".into(),
                display_name: "Opus 4.6".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "claude-opus-4-5".into(),
                display_name: "Opus 4.5".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "claude-opus-4-5-20251101".into(),
                display_name: "Opus 4.5 (2025-11-01)".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "claude-opus-4-1".into(),
                display_name: "Opus 4.1".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "claude-sonnet-4-6".into(),
        cheapest_fastest: "claude-haiku-4-5".into(),
    }
}

pub(super) fn codex_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from developers.openai.com/api/docs/models/all.
    // OpenAI uses dots in its public IDs (e.g. `gpt-5.4`, `gpt-5.1-codex-mini`).
    RuntimeModelCatalog {
        runtime: "codex".into(),
        models: vec![
            // Fast tier
            RuntimeModel {
                id: "gpt-5.4-nano".into(),
                display_name: "GPT-5.4 nano".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gpt-5-nano".into(),
                display_name: "GPT-5 nano".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gpt-5.4-mini".into(),
                display_name: "GPT-5.4 mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gpt-5-mini".into(),
                display_name: "GPT-5 mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gpt-5.1-codex-mini".into(),
                display_name: "GPT-5.1 Codex mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            // Balanced tier
            RuntimeModel {
                id: "gpt-5.4".into(),
                display_name: "GPT-5.4".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "gpt-5".into(),
                display_name: "GPT-5".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "gpt-5-codex".into(),
                display_name: "GPT-5 Codex".into(),
                tier: RuntimeModelTier::Balanced,
            },
            // Max tier
            RuntimeModel {
                id: "gpt-5.4-pro".into(),
                display_name: "GPT-5.4 Pro".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "gpt-5-codex".into(),
        cheapest_fastest: "gpt-5.1-codex-mini".into(),
    }
}

pub(super) fn gemini_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from ai.google.dev/gemini-api/docs/models.
    // Google uses dots in its public IDs (e.g. `gemini-2.5-pro`,
    // `gemini-3.1-pro-preview`). The 3.x series is currently preview-only.
    RuntimeModelCatalog {
        runtime: "gemini".into(),
        models: vec![
            // Fast tier
            RuntimeModel {
                id: "gemini-2.5-flash-lite".into(),
                display_name: "Gemini 2.5 Flash-Lite".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gemini-3.1-flash-lite-preview".into(),
                display_name: "Gemini 3.1 Flash-Lite (preview)".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gemini-2.5-flash".into(),
                display_name: "Gemini 2.5 Flash".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gemini-3-flash-preview".into(),
                display_name: "Gemini 3 Flash (preview)".into(),
                tier: RuntimeModelTier::Fast,
            },
            // Balanced / Max tier
            RuntimeModel {
                id: "gemini-2.5-pro".into(),
                display_name: "Gemini 2.5 Pro".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "gemini-3.1-pro-preview".into(),
                display_name: "Gemini 3.1 Pro (preview)".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "gemini-2.5-pro".into(),
        cheapest_fastest: "gemini-2.5-flash-lite".into(),
    }
}

pub(super) fn copilot_catalog() -> RuntimeModelCatalog {
    // GitHub Copilot proxies multiple providers. Identifiers below are the
    // provider-native IDs Copilot currently exposes via its model picker;
    // the Copilot CLI passes them through unchanged.
    RuntimeModelCatalog {
        runtime: "copilot".into(),
        models: vec![
            // Fast tier
            RuntimeModel {
                id: "gpt-5.4-mini".into(),
                display_name: "GPT-5.4 mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "claude-haiku-4-5".into(),
                display_name: "Claude Haiku 4.5".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gemini-2.5-flash".into(),
                display_name: "Gemini 2.5 Flash".into(),
                tier: RuntimeModelTier::Fast,
            },
            // Balanced tier
            RuntimeModel {
                id: "gpt-5.4".into(),
                display_name: "GPT-5.4".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "claude-sonnet-4-6".into(),
                display_name: "Claude Sonnet 4.6".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "gemini-2.5-pro".into(),
                display_name: "Gemini 2.5 Pro".into(),
                tier: RuntimeModelTier::Balanced,
            },
            // Max tier
            RuntimeModel {
                id: "gpt-5.4-pro".into(),
                display_name: "GPT-5.4 Pro".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "claude-opus-4-7".into(),
                display_name: "Claude Opus 4.7".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "claude-sonnet-4-6".into(),
        cheapest_fastest: "gpt-5.4-mini".into(),
    }
}

pub(super) fn vibe_catalog() -> RuntimeModelCatalog {
    // Identifiers sourced from docs.mistral.ai/getting-started/models/models_overview.
    // Mistral encodes dates as `YY-MM` within the versioned suffix
    // (e.g. `mistral-small-4-0-26-03` == Small 4.0 released 2026-03).
    RuntimeModelCatalog {
        runtime: "vibe".into(),
        models: vec![
            // Fast tier
            RuntimeModel {
                id: "mistral-small-4-0-26-03".into(),
                display_name: "Mistral Small 4".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "mistral-small-3-2-25-06".into(),
                display_name: "Mistral Small 3.2".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "codestral-25-08".into(),
                display_name: "Codestral".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "devstral-2-25-12".into(),
                display_name: "Devstral 2".into(),
                tier: RuntimeModelTier::Fast,
            },
            // Balanced tier
            RuntimeModel {
                id: "mistral-medium-3-1-25-08".into(),
                display_name: "Mistral Medium 3.1".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "mistral-large-3-25-12".into(),
                display_name: "Mistral Large 3".into(),
                tier: RuntimeModelTier::Balanced,
            },
            // Max tier (reasoning variants)
            RuntimeModel {
                id: "magistral-small-1-2-25-09".into(),
                display_name: "Magistral Small 1.2".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "magistral-medium-1-2-25-09".into(),
                display_name: "Magistral Medium 1.2".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "mistral-large-3-25-12".into(),
        cheapest_fastest: "mistral-small-4-0-26-03".into(),
    }
}

pub(super) fn opencode_catalog() -> RuntimeModelCatalog {
    // OpenCode is provider-agnostic. Model identifiers use the
    // `<provider>/<model-id>` form where <model-id> is the provider's native
    // identifier (see the per-provider catalogs above for sources).
    RuntimeModelCatalog {
        runtime: "opencode".into(),
        models: vec![
            // Fast tier
            RuntimeModel {
                id: "anthropic/claude-haiku-4-5".into(),
                display_name: "Claude Haiku 4.5".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "openai/gpt-5.4-mini".into(),
                display_name: "GPT-5.4 mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "openai/gpt-5.1-codex-mini".into(),
                display_name: "GPT-5.1 Codex mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "google/gemini-2.5-flash".into(),
                display_name: "Gemini 2.5 Flash".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "mistral/mistral-small-4-0-26-03".into(),
                display_name: "Mistral Small 4".into(),
                tier: RuntimeModelTier::Fast,
            },
            // Balanced tier
            RuntimeModel {
                id: "anthropic/claude-sonnet-4-6".into(),
                display_name: "Claude Sonnet 4.6".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "openai/gpt-5.4".into(),
                display_name: "GPT-5.4".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "openai/gpt-5-codex".into(),
                display_name: "GPT-5 Codex".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "google/gemini-2.5-pro".into(),
                display_name: "Gemini 2.5 Pro".into(),
                tier: RuntimeModelTier::Balanced,
            },
            // Max tier
            RuntimeModel {
                id: "anthropic/claude-opus-4-7".into(),
                display_name: "Claude Opus 4.7".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "openai/gpt-5.4-pro".into(),
                display_name: "GPT-5.4 Pro".into(),
                tier: RuntimeModelTier::Max,
            },
            RuntimeModel {
                id: "google/gemini-3.1-pro-preview".into(),
                display_name: "Gemini 3.1 Pro (preview)".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "anthropic/claude-sonnet-4-6".into(),
        cheapest_fastest: "anthropic/claude-haiku-4-5".into(),
    }
}
