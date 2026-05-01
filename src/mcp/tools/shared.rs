use std::future::Future;
use std::iter::once;
use std::time::Duration;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use tokio::time::sleep;

use crate::mcp::automation::{
    AccessibilityQueryError, get_accessibility_element, list_accessibility_elements,
};
use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{
    ElementKind, GetElementResult, ListElementsResult, RegistryClient, RegistryError,
    RegistryRequest,
};
use crate::mcp::tool::ToolError;

const WINDOW_SCOPED_LIST_ELEMENTS_RETRY_DELAYS: [Duration; 3] = [
    Duration::from_millis(100),
    Duration::from_millis(250),
    Duration::from_millis(500),
];

/// Decode JSON params, mapping errors to `ToolError::InvalidParams` so the
/// dispatcher returns the JSON-RPC `InvalidParams` code.
///
/// # Errors
/// Returns `ToolError::InvalidParams` when `params` does not match `T`.
pub fn decode_params<T: DeserializeOwned>(params: Value) -> Result<T, ToolError> {
    serde_json::from_value(params).map_err(|error| ToolError::invalid(error.to_string()))
}

/// Turn a successful JSON payload into a pretty-printed text `ToolResult`.
///
/// # Errors
/// Returns `ToolError::internal` when the payload cannot be serialized (a
/// serde-internal failure).
pub fn ok_text<T: Serialize>(payload: &T) -> Result<ToolResult, ToolError> {
    ToolResult::json_text(payload).map_err(|error| ToolError::internal(error.to_string()))
}

/// Map a `RegistryError` into the tool-level `ToolError`. Unavailable and
/// server errors surface as `ToolError::Internal` so the LLM sees them in
/// the tool result with `isError: true`; protocol errors become
/// `InvalidParams` so the client retries with adjusted input.
#[must_use]
pub fn map_registry_error(error: &RegistryError) -> ToolError {
    match error {
        RegistryError::Unavailable { .. }
        | RegistryError::Server { .. }
        | RegistryError::Timeout { .. }
        | RegistryError::Closed { .. } => ToolError::internal(error.to_string()),
        RegistryError::Protocol { .. } => ToolError::invalid(error.to_string()),
    }
}

#[must_use]
pub fn map_accessibility_query_error(error: &AccessibilityQueryError) -> ToolError {
    ToolError::internal(error.to_string())
}

pub async fn resolve_list_elements(
    client: &RegistryClient,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
) -> Result<ListElementsResult, ToolError> {
    resolve_list_elements_with(client, window_id, kind, list_accessibility_elements).await
}

/// Resolve `list_elements` from the registry first, then optionally enrich the
/// first empty success with the AX helper. Fresh window-scoped, unfiltered
/// queries are the only class that retries after an empty result, with an
/// additional worst-case tail of 850 ms (100 + 250 + 500) before returning the
/// final empty success. Follow-up attempts are registry-only so the helper cost
/// is paid at most once per request.
pub(crate) async fn resolve_list_elements_with<F, Fut>(
    client: &RegistryClient,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
    fallback: F,
) -> Result<ListElementsResult, ToolError>
where
    F: Fn(Option<i64>, Option<ElementKind>) -> Fut + Copy,
    Fut: Future<Output = Result<ListElementsResult, AccessibilityQueryError>>,
{
    match resolve_list_elements_once(client, window_id, kind, fallback).await {
        Ok(result) if !result.elements.is_empty() => Ok(result),
        Ok(result) => resolve_list_elements_after_empty(client, window_id, kind, result).await,
        Err(error) => Err(error),
    }
}

fn list_elements_retry_delays(
    window_id: Option<i64>,
    kind: Option<ElementKind>,
) -> impl Iterator<Item = Option<Duration>> {
    let retry_delays = if window_id.is_some() && kind.is_none() {
        WINDOW_SCOPED_LIST_ELEMENTS_RETRY_DELAYS.as_slice()
    } else {
        &[]
    };
    once(None).chain(retry_delays.iter().copied().map(Some))
}

async fn resolve_list_elements_after_empty(
    client: &RegistryClient,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
    initial_empty: ListElementsResult,
) -> Result<ListElementsResult, ToolError> {
    let mut last_empty_result = initial_empty;
    for delay in list_elements_retry_delays(window_id, kind).skip(1) {
        if let Some(delay) = delay {
            sleep(delay).await;
        }
        match request_list_elements_from_registry(client, window_id, kind).await {
            Ok(result) if !result.elements.is_empty() => return Ok(result),
            Ok(result) => {
                last_empty_result = result;
            }
            Err(_) => {}
        }
    }
    Ok(last_empty_result)
}

async fn resolve_list_elements_once<F, Fut>(
    client: &RegistryClient,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
    fallback: F,
) -> Result<ListElementsResult, ToolError>
where
    F: Fn(Option<i64>, Option<ElementKind>) -> Fut,
    Fut: Future<Output = Result<ListElementsResult, AccessibilityQueryError>>,
{
    let registry_result = request_list_elements_from_registry(client, window_id, kind).await;
    resolve_list_elements_with_fallback(registry_result, window_id, kind, fallback).await
}

async fn resolve_list_elements_with_fallback<F, Fut>(
    registry_result: Result<ListElementsResult, RegistryError>,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
    fallback: F,
) -> Result<ListElementsResult, ToolError>
where
    F: Fn(Option<i64>, Option<ElementKind>) -> Fut,
    Fut: Future<Output = Result<ListElementsResult, AccessibilityQueryError>>,
{
    match registry_result {
        Ok(result) => resolve_empty_list_elements(result, window_id, kind, fallback).await,
        Err(registry_error) => {
            fallback_or_combined_error(&registry_error.to_string(), fallback(window_id, kind).await)
        }
    }
}

async fn resolve_empty_list_elements<F, Fut>(
    registry_result: ListElementsResult,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
    fallback: F,
) -> Result<ListElementsResult, ToolError>
where
    F: Fn(Option<i64>, Option<ElementKind>) -> Fut,
    Fut: Future<Output = Result<ListElementsResult, AccessibilityQueryError>>,
{
    if !registry_result.elements.is_empty() {
        return Ok(registry_result);
    }
    match fallback(window_id, kind).await {
        Ok(fallback_result) if !fallback_result.elements.is_empty() => Ok(fallback_result),
        Ok(_) | Err(_) => Ok(registry_result),
    }
}

fn fallback_or_combined_error<T>(
    registry_error: &str,
    fallback_result: Result<T, AccessibilityQueryError>,
) -> Result<T, ToolError> {
    match fallback_result {
        Ok(result) => Ok(result),
        Err(accessibility_error) => Err(ToolError::internal(format!(
            "{registry_error}; accessibility fallback failed: {accessibility_error}"
        ))),
    }
}

fn get_element_request(client: &RegistryClient, identifier: &str) -> RegistryRequest {
    RegistryRequest::GetElement {
        id: client.next_request_id(),
        identifier: identifier.to_string(),
    }
}

fn map_not_found_fallback_error(
    registry_error: &RegistryError,
    accessibility_error: AccessibilityQueryError,
) -> ToolError {
    match accessibility_error {
        AccessibilityQueryError::NotFound => map_registry_error(registry_error),
        other => map_accessibility_query_error(&other),
    }
}

async fn resolve_get_element_fallback<F, Fut>(
    identifier: &str,
    registry_error: RegistryError,
    fallback: F,
) -> Result<GetElementResult, ToolError>
where
    F: Fn(String) -> Fut,
    Fut: Future<Output = Result<GetElementResult, AccessibilityQueryError>>,
{
    let fallback_result = fallback(identifier.to_string()).await;
    if let RegistryError::Server { code, .. } = &registry_error
        && code == "not-found"
    {
        return fallback_result
            .map_err(|error| map_not_found_fallback_error(&registry_error, error));
    }
    fallback_or_combined_error(&registry_error.to_string(), fallback_result)
}

async fn request_list_elements_from_registry(
    client: &RegistryClient,
    window_id: Option<i64>,
    kind: Option<ElementKind>,
) -> Result<ListElementsResult, RegistryError> {
    let id = client.next_request_id();
    let request = RegistryRequest::ListElements {
        id,
        window_id,
        kind,
    };
    client.request::<ListElementsResult>(&request).await
}

pub async fn resolve_get_element(
    client: &RegistryClient,
    identifier: &str,
) -> Result<GetElementResult, ToolError> {
    resolve_get_element_with(client, identifier, |identifier| async move {
        get_accessibility_element(&identifier).await
    })
    .await
}

pub(crate) async fn resolve_get_element_with<F, Fut>(
    client: &RegistryClient,
    identifier: &str,
    fallback: F,
) -> Result<GetElementResult, ToolError>
where
    F: Fn(String) -> Fut,
    Fut: Future<Output = Result<GetElementResult, AccessibilityQueryError>>,
{
    let request = get_element_request(client, identifier);
    match client.request::<GetElementResult>(&request).await {
        Ok(result) => Ok(result),
        Err(registry_error) => {
            resolve_get_element_fallback(identifier, registry_error, fallback).await
        }
    }
}
