use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::daemon::protocol::{
    OpenRouterModelCatalogResponse, OpenRouterModelCatalogSource, OpenRouterModelEntry,
};
use crate::daemon::state::task_board_openrouter_token;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

const DEFAULT_OPENROUTER_BASE_URL: &str = "https://openrouter.ai/api/v1";
const CACHE_TTL: Duration = Duration::from_secs(30 * 60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const HARNESS_REFERER: &str = "https://harness.dev";
const HARNESS_TITLE: &str = "Harness";

static CACHE: LazyLock<Mutex<Option<CachedCatalog>>> = LazyLock::new(|| Mutex::new(None));

struct CachedCatalog {
    fetched_at: Instant,
    fingerprint: String,
    models: Vec<OpenRouterModelEntry>,
}

#[derive(Deserialize)]
struct UpstreamModelListResponse {
    data: Vec<UpstreamModelEntry>,
}

#[derive(Deserialize)]
struct UpstreamModelEntry {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    context_length: Option<u64>,
    #[serde(default)]
    supported_parameters: Vec<String>,
}

/// Return the OpenRouter model catalog, serving the in-memory cache when it is
/// still fresh and the API key fingerprint matches. On cache miss or expiry the
/// daemon issues one upstream request against `/api/v1/models`. Callers receive
/// the same payload via the cache or live source; the response declares which.
///
/// # Errors
/// Returns [`CliError`] when no API key is configured or the upstream request
/// fails. Callers may fall back to the static descriptor catalog when this
/// errors.
pub async fn list_openrouter_models() -> Result<OpenRouterModelCatalogResponse, CliError> {
    let token = task_board_openrouter_token().ok_or_else(|| {
        CliErrorKind::workflow_io(
            "openrouter_api_key_unset: configure an OpenRouter API key before listing models",
        )
    })?;
    let fingerprint = fingerprint_token(&token);
    if let Some(cached) = read_cached(&fingerprint) {
        return Ok(catalog_from(cached, OpenRouterModelCatalogSource::Cache));
    }
    let models = fetch_upstream(&token).await?;
    store_cached(&fingerprint, models.clone());
    Ok(catalog_from(models, OpenRouterModelCatalogSource::Live))
}

#[cfg(test)]
fn invalidate_openrouter_model_cache() {
    if let Ok(mut guard) = CACHE.lock() {
        *guard = None;
    }
}

fn read_cached(fingerprint: &str) -> Option<Vec<OpenRouterModelEntry>> {
    let guard = CACHE.lock().ok()?;
    let cached = guard.as_ref()?;
    if cached.fingerprint != fingerprint {
        return None;
    }
    if cached.fetched_at.elapsed() >= CACHE_TTL {
        return None;
    }
    Some(cached.models.clone())
}

fn store_cached(fingerprint: &str, models: Vec<OpenRouterModelEntry>) {
    if let Ok(mut guard) = CACHE.lock() {
        *guard = Some(CachedCatalog {
            fetched_at: Instant::now(),
            fingerprint: fingerprint.to_string(),
            models,
        });
    }
}

fn catalog_from(
    models: Vec<OpenRouterModelEntry>,
    source: OpenRouterModelCatalogSource,
) -> OpenRouterModelCatalogResponse {
    OpenRouterModelCatalogResponse {
        models,
        fetched_at: utc_now(),
        source,
    }
}

fn fingerprint_token(token: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    token.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

async fn fetch_upstream(token: &str) -> Result<Vec<OpenRouterModelEntry>, CliError> {
    let base_url = std::env::var("OPENROUTER_API_URL")
        .unwrap_or_else(|_| DEFAULT_OPENROUTER_BASE_URL.to_string());
    let url = format!("{}/models", base_url.trim_end_matches('/'));
    let response = reqwest::Client::new()
        .get(&url)
        .bearer_auth(token)
        .header("HTTP-Referer", HARNESS_REFERER)
        .header("X-Title", HARNESS_TITLE)
        .timeout(REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!(
                "openrouter_models_unreachable: {url}: {error}"
            ))
        })?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let detail = if body.trim().is_empty() {
            format!("HTTP {status}")
        } else {
            format!("HTTP {status}: {}", body.trim())
        };
        return Err(CliErrorKind::workflow_io(format!(
            "openrouter_models_rejected: {url}: {detail}"
        ))
        .into());
    }
    let parsed: UpstreamModelListResponse = response.json().await.map_err(|error| {
        CliErrorKind::workflow_parse(format!(
            "openrouter_models_decode_failed: {url}: {error}"
        ))
    })?;
    Ok(parsed
        .data
        .into_iter()
        .map(|entry| OpenRouterModelEntry {
            id: entry.id,
            name: entry.name,
            context_length: entry.context_length,
            supported_parameters: entry.supported_parameters,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_is_stable_for_same_token() {
        assert_eq!(fingerprint_token("abc"), fingerprint_token("abc"));
        assert_ne!(fingerprint_token("abc"), fingerprint_token("abd"));
    }

    #[test]
    fn cache_serves_when_fingerprint_matches() {
        invalidate_openrouter_model_cache();
        let model = OpenRouterModelEntry {
            id: "anthropic/claude-3.7-sonnet".to_string(),
            name: Some("Claude 3.7 Sonnet".to_string()),
            context_length: Some(200_000),
            supported_parameters: vec!["temperature".to_string()],
        };
        store_cached("abc", vec![model.clone()]);
        let cached = read_cached("abc").expect("cache hit");
        assert_eq!(cached.len(), 1);
        assert_eq!(cached[0].id, model.id);
        assert!(read_cached("def").is_none());
        invalidate_openrouter_model_cache();
        assert!(read_cached("abc").is_none());
    }
}
