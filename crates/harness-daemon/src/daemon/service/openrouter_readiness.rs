//! Live `OpenRouter` credential and model check for the headless readiness gate.
//!
//! Both prerequisites collapse into a single authenticated request against the
//! per-key `/models/user` endpoint. That endpoint requires the credential, so a
//! rejected, expired, or revoked key surfaces as a definite rejection rather
//! than passing on mere presence; the same response also lists the models the
//! key can actually reach, which is what makes model availability reflect the
//! live provider instead of a static catalog. No returned detail ever contains
//! the token: only HTTP status codes and transport reasons are propagated.

use std::env;
use std::time::Duration;

use reqwest::StatusCode;
use serde::Deserialize;

const DEFAULT_OPENROUTER_BASE_URL: &str = "https://openrouter.ai/api/v1";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const HARNESS_REFERER: &str = "https://harness.dev";
const HARNESS_TITLE: &str = "Harness";

/// Outcome of validating the configured credential against the live provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum OpenRouterCredential {
    Accepted,
    Rejected(String),
    Unverified(String),
}

pub(crate) struct OpenRouterReadiness {
    pub credential: OpenRouterCredential,
    /// `Some(true/false)` once the live model list is known, `None` when the
    /// list could not be retrieved (rejected credential or provider outage).
    pub model_available: Option<bool>,
}

#[derive(Deserialize)]
struct UserModelList {
    // No serde default: a 200 whose body lacks `data` (an unrecognized envelope)
    // must deserialize-fail into `model_available: None` so the caller falls back
    // to the static catalog, rather than silently reading as "model unavailable".
    data: Vec<UserModel>,
}

#[derive(Deserialize)]
struct UserModel {
    id: String,
}

/// Validate the configured `OpenRouter` credential and check whether the
/// requested model is offered to that key, using the live `/models/user`
/// endpoint. `OPENROUTER_API_URL` overrides the base URL for tests.
pub(crate) async fn probe_openrouter_readiness(
    token: &str,
    requested_model: &str,
) -> OpenRouterReadiness {
    let base_url =
        env::var("OPENROUTER_API_URL").unwrap_or_else(|_| DEFAULT_OPENROUTER_BASE_URL.to_string());
    probe_at(&base_url, token, requested_model).await
}

async fn probe_at(base_url: &str, token: &str, requested_model: &str) -> OpenRouterReadiness {
    let url = format!("{}/models/user", base_url.trim_end_matches('/'));
    let Ok(client) = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
    else {
        return unverified("could not build HTTP client");
    };
    let response = match client
        .get(&url)
        .bearer_auth(token)
        .header("HTTP-Referer", HARNESS_REFERER)
        .header("X-Title", HARNESS_TITLE)
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => return unverified(transport_detail(&error)),
    };
    classify_response(response, requested_model).await
}

async fn classify_response(
    response: reqwest::Response,
    requested_model: &str,
) -> OpenRouterReadiness {
    let status = response.status();
    if status.is_success() {
        return match response.json::<UserModelList>().await {
            Ok(list) => OpenRouterReadiness {
                credential: OpenRouterCredential::Accepted,
                model_available: Some(list.data.iter().any(|model| model.id == requested_model)),
            },
            Err(_) => OpenRouterReadiness {
                credential: OpenRouterCredential::Accepted,
                model_available: None,
            },
        };
    }
    if matches!(
        status,
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN | StatusCode::PAYMENT_REQUIRED
    ) {
        return OpenRouterReadiness {
            credential: OpenRouterCredential::Rejected(format!("HTTP {status}")),
            model_available: None,
        };
    }
    OpenRouterReadiness {
        credential: OpenRouterCredential::Unverified(format!("HTTP {status}")),
        model_available: None,
    }
}

fn transport_detail(error: &reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "request timed out"
    } else if error.is_connect() {
        "could not connect"
    } else {
        "request failed"
    }
}

fn unverified(detail: &str) -> OpenRouterReadiness {
    OpenRouterReadiness {
        credential: OpenRouterCredential::Unverified(detail.to_string()),
        model_available: None,
    }
}

#[cfg(test)]
#[path = "openrouter_readiness_tests.rs"]
mod tests;
