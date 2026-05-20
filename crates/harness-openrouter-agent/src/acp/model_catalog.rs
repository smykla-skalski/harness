//! Live OpenRouter model catalog assembled for ACP `session/new` responses.
//!
//! Combines a curated default list (so the model picker is never empty when
//! the live API call fails) with the live `/models/user` response. The
//! curated entries always appear first.

use agent_client_protocol::schema::{ModelId, ModelInfo, SessionModelState};

use crate::openrouter::{ModelEntry, OpenRouterClient};

/// Default model presented to the user when the daemon does not pin one.
pub const DEFAULT_MODEL_ID: &str = "anthropic/claude-sonnet-4-6";

/// Curated, hardcoded fallback list that mirrors the catalogs.rs entry.
#[must_use]
pub fn curated_models() -> Vec<ModelInfo> {
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
    .map(|(id, name)| ModelInfo::new(ModelId::new(id.to_owned()), name.to_owned()))
    .collect()
}

/// Fetch the per-key model list and merge it with the curated defaults. The
/// curated list always appears first; live entries with the same `id` are
/// skipped to avoid duplicates. Errors fall back to the curated list with a
/// trace warning so a temporary outage never breaks `session/new`.
pub async fn build_session_models(
    client: &OpenRouterClient,
    selected_model: &str,
) -> SessionModelState {
    let mut models = curated_models();
    match client.list_models().await {
        Ok(response) => {
            for entry in response.data {
                if models.iter().any(|m| m.model_id.0.as_ref() == entry.id) {
                    continue;
                }
                models.push(model_info_from_entry(entry));
            }
        }
        Err(error) => {
            tracing::warn!(%error, "failed to fetch live OpenRouter model list; using curated fallback");
        }
    }
    SessionModelState::new(ModelId::new(selected_model.to_owned()), models)
}

fn model_info_from_entry(entry: ModelEntry) -> ModelInfo {
    let id = ModelId::new(entry.id.clone());
    let name = entry.name.clone().unwrap_or(entry.id);
    ModelInfo::new(id, name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curated_list_includes_default_model() {
        let models = curated_models();
        assert!(models
            .iter()
            .any(|m| m.model_id.0.as_ref() == DEFAULT_MODEL_ID));
    }

    #[test]
    fn model_info_falls_back_to_id_when_name_missing() {
        let info = model_info_from_entry(ModelEntry {
            id: "x/y".to_owned(),
            name: None,
            context_length: None,
            supported_parameters: Vec::new(),
        });
        assert_eq!(info.model_id.0.as_ref(), "x/y");
        assert_eq!(info.name, "x/y");
    }
}
