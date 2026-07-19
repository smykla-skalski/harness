//! Live OpenRouter model catalog assembled for ACP `session/new` responses.
//!
//! Combines a curated default list (so the model picker is never empty when
//! the live API call fails) with the live `/models/user` response. The
//! curated entries always appear first, advertised as a `model`-category
//! session config option.

use agent_client_protocol::schema::v1::{
    SessionConfigOption, SessionConfigOptionCategory, SessionConfigSelectOption,
    SessionConfigSelectOptions,
};

use crate::openrouter::{ModelEntry, OpenRouterClient};

/// Default model presented to the user when the daemon does not pin one.
pub const DEFAULT_MODEL_ID: &str = "anthropic/claude-sonnet-4-6";

/// Config option id the model catalog is advertised under.
pub const MODEL_CONFIG_OPTION_ID: &str = "model";

/// Curated, hardcoded fallback list that mirrors the catalogs.rs entry.
#[must_use]
pub fn curated_models() -> Vec<SessionConfigSelectOption> {
    [
        ("anthropic/claude-haiku-4-5", "Claude Haiku 4.5"),
        ("anthropic/claude-sonnet-4-6", "Claude Sonnet 4.6"),
        ("anthropic/claude-opus-4-7", "Claude Opus 4.7"),
        ("openai/gpt-5.4-mini", "GPT-5.4 mini"),
        ("openai/gpt-5.5", "GPT-5.5"),
        ("google/gemini-2.5-flash", "Gemini 2.5 Flash"),
        ("google/gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("google/gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"),
    ]
    .into_iter()
    .map(|(id, name)| SessionConfigSelectOption::new(id, name))
    .collect()
}

/// Fetch the per-key model list and merge it with the curated defaults. The
/// curated list always appears first; live entries with the same id are
/// skipped. Errors fall back to the curated list with a trace warning so a
/// temporary outage never breaks `session/new`.
pub async fn build_model_config_option(
    client: &OpenRouterClient,
    selected_model: &str,
) -> SessionConfigOption {
    let mut options = curated_models();
    match client.list_models().await {
        Ok(response) => {
            for entry in response.data {
                if options.iter().any(|m| m.value.0.as_ref() == entry.id) {
                    continue;
                }
                options.push(select_option_from_entry(entry));
            }
        }
        Err(error) => {
            tracing::warn!(%error, "failed to fetch live OpenRouter model list; using curated fallback");
        }
    }
    SessionConfigOption::select(
        MODEL_CONFIG_OPTION_ID,
        "Model",
        selected_model.to_owned(),
        SessionConfigSelectOptions::Ungrouped(options),
    )
    .category(SessionConfigOptionCategory::Model)
}

fn select_option_from_entry(entry: ModelEntry) -> SessionConfigSelectOption {
    let name = entry.name.clone().unwrap_or_else(|| entry.id.clone());
    SessionConfigSelectOption::new(entry.id, name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curated_list_includes_default_model() {
        let models = curated_models();
        assert!(models.iter().any(|m| m.value.0.as_ref() == DEFAULT_MODEL_ID));
    }

    #[test]
    fn select_option_falls_back_to_id_when_name_missing() {
        let option = select_option_from_entry(ModelEntry {
            id: "x/y".to_owned(),
            name: None,
            context_length: None,
            supported_parameters: Vec::new(),
        });
        assert_eq!(option.value.0.as_ref(), "x/y");
        assert_eq!(option.name, "x/y");
    }
}
