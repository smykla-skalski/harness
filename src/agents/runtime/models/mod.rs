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
//!
//! Source-of-truth references consulted when maintaining these catalogs:
//! - Claude: <https://platform.claude.com/docs/en/docs/about-claude/models/overview>
//! - `OpenAI` (Codex): <https://developers.openai.com/api/docs/models/all>
//! - Gemini: <https://ai.google.dev/gemini-api/docs/models>
//! - Mistral (Vibe): <https://docs.mistral.ai/getting-started/models/models_overview/>
//! - GitHub Copilot: <https://docs.github.com/en/copilot/reference/ai-models/supported-models>

mod catalogs;

use std::collections::BTreeMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use self::catalogs::{
    claude_catalog, codex_catalog, copilot_catalog, gemini_catalog, opencode_catalog, vibe_catalog,
};

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

/// Reasoning/thinking parameter family exposed by a model. The UI uses this
/// to decide which CLI parameter name to show next to the effort picker and
/// whether to show it at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffortKind {
    /// No reasoning/thinking parameter accepted - the effort picker is hidden.
    None,
    /// Anthropic- and Google-style thinking budget (token-count based, but
    /// the UI exposes coarse levels mapped to budgets internally).
    ThinkingBudget,
    /// `OpenAI`-style `reasoning_effort` parameter with named levels.
    ReasoningEffort,
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
    /// Family of reasoning parameter the model accepts.
    #[serde(default = "effort_kind_none")]
    pub effort_kind: EffortKind,
    /// Allowed effort level names (empty when `effort_kind` is `None`).
    /// Ordered low → high so the UI can default to the first entry.
    #[serde(default)]
    pub effort_values: Vec<String>,
}

fn effort_kind_none() -> EffortKind {
    EffortKind::None
}

impl RuntimeModel {
    /// Whether this model accepts a reasoning/thinking parameter at all.
    #[must_use]
    pub fn supports_effort(&self) -> bool {
        !matches!(self.effort_kind, EffortKind::None)
    }
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
        Err(catalog
            .models
            .iter()
            .map(|entry| entry.id.clone())
            .collect())
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

    #[test]
    fn claude_sonnet_supports_thinking_budget() {
        let catalog = catalog_for("claude").unwrap();
        let sonnet = catalog
            .models
            .iter()
            .find(|m| m.id == "claude-sonnet-4-6")
            .expect("sonnet 4.6 present");
        assert_eq!(sonnet.effort_kind, EffortKind::ThinkingBudget);
        assert!(sonnet.supports_effort());
        assert!(!sonnet.effort_values.is_empty());
    }

    #[test]
    fn codex_thinking_model_uses_reasoning_effort() {
        let catalog = catalog_for("codex").unwrap();
        let thinking = catalog
            .models
            .iter()
            .find(|m| m.id == "gpt-5.5")
            .expect("gpt-5.5 present");
        assert_eq!(thinking.effort_kind, EffortKind::ReasoningEffort);
        assert!(thinking.effort_values.iter().any(|v| v == "xhigh"));
    }

    #[test]
    fn gemini_flash_lite_has_no_effort() {
        let catalog = catalog_for("gemini").unwrap();
        let lite = catalog
            .models
            .iter()
            .find(|m| m.id == "gemini-2.5-flash-lite")
            .expect("2.5 flash-lite present");
        assert_eq!(lite.effort_kind, EffortKind::None);
        assert!(!lite.supports_effort());
        assert!(lite.effort_values.is_empty());
    }

    #[test]
    fn effort_values_deserialize_default_when_absent() {
        let json = r#"{"id":"x","display_name":"X","tier":"fast"}"#;
        let model: RuntimeModel = serde_json::from_str(json).expect("parse");
        assert_eq!(model.effort_kind, EffortKind::None);
        assert!(model.effort_values.is_empty());
    }

    #[test]
    fn effort_kind_serializes_snake_case() {
        let catalog = catalog_for("claude").unwrap();
        let json = serde_json::to_string(catalog).expect("serialize");
        assert!(json.contains("\"effort_kind\":\"thinking_budget\""));
    }
}
