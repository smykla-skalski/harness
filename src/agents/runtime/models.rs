//! Per-runtime model catalogs for agent startup model selection.
//!
//! Each runtime adapter exposes a curated, hardcoded list of models that
//! Harness can request when spawning that runtime. The list is intentionally
//! static rather than queried from each provider's CLI: most CLIs do not
//! expose a stable model-list command, and a static catalog keeps daemon
//! startup deterministic. Update the lists below when providers ship new
//! model versions.
//!
//! Model namespaces do not overlap across runtimes; the daemon ships one
//! catalog per runtime keyed by runtime name and the UI filters by the
//! selected runtime.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

/// Coarse cost/speed tier used by the UI for ordering and by E2E tests for
/// picking the cheapest/fastest model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeModelTier {
    /// Cheapest and fastest tier - used for E2E tests.
    Fast,
    /// Default day-to-day tier balancing cost and capability.
    Balanced,
    /// Maximum capability tier.
    Max,
}

/// One model offered by a runtime.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeModel {
    /// Provider-specific model identifier passed back to the runtime.
    pub id: String,
    /// Human-readable name for the picker.
    pub display_name: String,
    /// Cost/speed tier metadata.
    pub tier: RuntimeModelTier,
}

/// All models a single runtime can spawn with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeModelCatalog {
    /// Runtime name (claude, codex, gemini, copilot, vibe, opencode).
    pub runtime: String,
    /// Models the user can choose from.
    pub models: Vec<RuntimeModel>,
    /// Identifier of the default model when none is explicitly requested.
    pub default: String,
    /// Identifier of the cheapest/fastest model (E2E tests use this).
    pub cheapest_fastest: String,
}

static REGISTRY: LazyLock<BTreeMap<&'static str, RuntimeModelCatalog>> = LazyLock::new(|| {
    let mut map = BTreeMap::new();
    map.insert("claude", claude_catalog());
    map.insert("codex", codex_catalog());
    map.insert("gemini", gemini_catalog());
    map.insert("copilot", copilot_catalog());
    map.insert("vibe", vibe_catalog());
    map.insert("opencode", opencode_catalog());
    map
});

fn claude_catalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog {
        runtime: "claude".into(),
        models: vec![
            RuntimeModel {
                id: "claude-haiku-4-5".into(),
                display_name: "Haiku 4.5".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "claude-sonnet-4-6".into(),
                display_name: "Sonnet 4.6".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "claude-opus-4-7".into(),
                display_name: "Opus 4.7".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "claude-sonnet-4-6".into(),
        cheapest_fastest: "claude-haiku-4-5".into(),
    }
}

fn codex_catalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog {
        runtime: "codex".into(),
        models: vec![
            RuntimeModel {
                id: "o4-mini".into(),
                display_name: "o4-mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gpt-5-codex".into(),
                display_name: "GPT-5 Codex".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "gpt-5-codex-max".into(),
                display_name: "GPT-5 Codex Max".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "gpt-5-codex".into(),
        cheapest_fastest: "o4-mini".into(),
    }
}

fn gemini_catalog() -> RuntimeModelCatalog {
    RuntimeModelCatalog {
        runtime: "gemini".into(),
        models: vec![
            RuntimeModel {
                id: "gemini-2.5-flash".into(),
                display_name: "Gemini 2.5 Flash".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gemini-2.5-pro".into(),
                display_name: "Gemini 2.5 Pro".into(),
                tier: RuntimeModelTier::Balanced,
            },
        ],
        default: "gemini-2.5-pro".into(),
        cheapest_fastest: "gemini-2.5-flash".into(),
    }
}

fn copilot_catalog() -> RuntimeModelCatalog {
    // Copilot proxies multiple providers; we expose the GitHub-published model
    // identifiers and let the user choose.
    RuntimeModelCatalog {
        runtime: "copilot".into(),
        models: vec![
            RuntimeModel {
                id: "gpt-4o-mini".into(),
                display_name: "GPT-4o mini".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "gpt-4o".into(),
                display_name: "GPT-4o".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "claude-sonnet-4.5".into(),
                display_name: "Claude Sonnet 4.5".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "gpt-4o".into(),
        cheapest_fastest: "gpt-4o-mini".into(),
    }
}

fn vibe_catalog() -> RuntimeModelCatalog {
    // Vibe wraps Mistral; their CLI accepts the provider's model ids.
    RuntimeModelCatalog {
        runtime: "vibe".into(),
        models: vec![
            RuntimeModel {
                id: "mistral-small-latest".into(),
                display_name: "Mistral Small".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "mistral-large-latest".into(),
                display_name: "Mistral Large".into(),
                tier: RuntimeModelTier::Balanced,
            },
        ],
        default: "mistral-large-latest".into(),
        cheapest_fastest: "mistral-small-latest".into(),
    }
}

fn opencode_catalog() -> RuntimeModelCatalog {
    // OpenCode is provider-agnostic; we ship a small curated set spanning
    // popular providers so users can pick a familiar model.
    RuntimeModelCatalog {
        runtime: "opencode".into(),
        models: vec![
            RuntimeModel {
                id: "anthropic/claude-haiku-4-5".into(),
                display_name: "Claude Haiku 4.5".into(),
                tier: RuntimeModelTier::Fast,
            },
            RuntimeModel {
                id: "anthropic/claude-sonnet-4-6".into(),
                display_name: "Claude Sonnet 4.6".into(),
                tier: RuntimeModelTier::Balanced,
            },
            RuntimeModel {
                id: "openai/gpt-5-codex".into(),
                display_name: "GPT-5 Codex".into(),
                tier: RuntimeModelTier::Max,
            },
        ],
        default: "anthropic/claude-sonnet-4-6".into(),
        cheapest_fastest: "anthropic/claude-haiku-4-5".into(),
    }
}

/// Look up the model catalog for a runtime.
#[must_use]
pub fn catalog_for(runtime: &str) -> Option<&'static RuntimeModelCatalog> {
    REGISTRY.get(runtime)
}

/// Return every runtime catalog sorted by runtime name.
#[must_use]
pub fn all_catalogs() -> Vec<RuntimeModelCatalog> {
    REGISTRY.values().cloned().collect()
}

/// Validate that a model id is offered by the given runtime.
///
/// Returns `Ok(())` when the model is in the catalog, `Err` with the list of
/// valid ids otherwise. Unknown runtimes return `Err` with an empty list.
///
/// # Errors
/// Returns the list of valid model ids for the runtime when validation fails.
pub fn validate_model(runtime: &str, model: &str) -> Result<(), Vec<String>> {
    let Some(catalog) = catalog_for(runtime) else {
        return Err(Vec::new());
    };
    if catalog.models.iter().any(|entry| entry.id == model) {
        Ok(())
    } else {
        Err(catalog.models.iter().map(|entry| entry.id.clone()).collect())
    }
}

/// Resolve the effective model id for a runtime, falling back to the runtime
/// default when the caller did not specify one.
#[must_use]
pub fn effective_model(runtime: &str, requested: Option<&str>) -> Option<String> {
    let catalog = catalog_for(runtime)?;
    Some(requested.unwrap_or(&catalog.default).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_known_runtime_has_a_catalog() {
        for runtime in ["claude", "codex", "gemini", "copilot", "vibe", "opencode"] {
            assert!(
                catalog_for(runtime).is_some(),
                "missing catalog for runtime '{runtime}'"
            );
        }
    }

    #[test]
    fn unknown_runtime_returns_none() {
        assert!(catalog_for("not-a-runtime").is_none());
    }

    #[test]
    fn each_catalog_default_and_cheapest_are_in_models() {
        for catalog in all_catalogs() {
            let ids: Vec<&str> = catalog.models.iter().map(|m| m.id.as_str()).collect();
            assert!(
                ids.contains(&catalog.default.as_str()),
                "{} default '{}' not in models",
                catalog.runtime,
                catalog.default
            );
            assert!(
                ids.contains(&catalog.cheapest_fastest.as_str()),
                "{} cheapest_fastest '{}' not in models",
                catalog.runtime,
                catalog.cheapest_fastest
            );
        }
    }

    #[test]
    fn each_catalog_has_at_least_one_fast_tier_model() {
        for catalog in all_catalogs() {
            assert!(
                catalog
                    .models
                    .iter()
                    .any(|m| m.tier == RuntimeModelTier::Fast),
                "{} has no Fast-tier model",
                catalog.runtime
            );
        }
    }

    #[test]
    fn validate_model_accepts_listed_id() {
        assert!(validate_model("claude", "claude-haiku-4-5").is_ok());
    }

    #[test]
    fn validate_model_rejects_unlisted_id_and_returns_valid_ids() {
        let err = validate_model("claude", "claude-haiku-3").unwrap_err();
        assert!(!err.is_empty(), "valid ids list should not be empty");
        assert!(err.contains(&"claude-sonnet-4-6".to_string()));
    }

    #[test]
    fn validate_model_unknown_runtime_returns_empty_list() {
        let err = validate_model("not-a-runtime", "x").unwrap_err();
        assert!(err.is_empty());
    }

    #[test]
    fn effective_model_returns_request_when_present() {
        let resolved = effective_model("claude", Some("claude-opus-4-7")).unwrap();
        assert_eq!(resolved, "claude-opus-4-7");
    }

    #[test]
    fn effective_model_falls_back_to_default() {
        let resolved = effective_model("claude", None).unwrap();
        assert_eq!(resolved, "claude-sonnet-4-6");
    }

    #[test]
    fn effective_model_returns_none_for_unknown_runtime() {
        assert!(effective_model("not-a-runtime", None).is_none());
    }

    #[test]
    fn all_catalogs_are_sorted_by_runtime_name() {
        let catalogs = all_catalogs();
        let names: Vec<&str> = catalogs.iter().map(|c| c.runtime.as_str()).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        assert_eq!(names, sorted);
    }

    #[test]
    fn catalogs_serialize_with_snake_case_tier() {
        let catalog = catalog_for("claude").unwrap();
        let json = serde_json::to_string(catalog).expect("serialize");
        assert!(json.contains("\"tier\":\"fast\""));
        assert!(json.contains("\"tier\":\"balanced\""));
        assert!(json.contains("\"tier\":\"max\""));
    }
}
