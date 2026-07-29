use reqwest::Method;
use serde_json::{Value, json};

use super::{DaemonHttpClient, OPENROUTER_MODEL, SmokeFailure};

pub(super) fn fail_on_openrouter_error(
    http: &DaemonHttpClient,
    correlation_id: &str,
) -> Result<(), SmokeFailure> {
    let transcript = read(http, correlation_id).map_err(|error| {
        SmokeFailure::new(
            correlation_id,
            "openrouter",
            OPENROUTER_MODEL,
            "transcript_poll",
            error,
        )
    })?;
    let Some(diagnostic) = error_diagnostic(&transcript) else {
        return Ok(());
    };
    Err(SmokeFailure::new(
        correlation_id,
        "openrouter",
        OPENROUTER_MODEL,
        "execution",
        diagnostic,
    ))
}

pub(super) fn timeout_failure(
    http: &DaemonHttpClient,
    correlation_id: &str,
    inspect: &Value,
) -> SmokeFailure {
    let transcript =
        read(http, correlation_id).unwrap_or_else(|error| json!({ "read_error": error }));
    SmokeFailure::new(
        correlation_id,
        "openrouter",
        OPENROUTER_MODEL,
        "result_collection",
        format!(
            "timed out waiting for terminal state and report; inspect={inspect}; transcript={transcript}"
        ),
    )
}

fn read(http: &DaemonHttpClient, correlation_id: &str) -> Result<Value, String> {
    let path = format!("/v1/managed-agents/acp/transcript?session_id={correlation_id}");
    http.request_json(Method::GET, &path, None)
}

fn error_diagnostic(transcript: &Value) -> Option<&str> {
    transcript["entries"]
        .as_array()?
        .iter()
        .filter_map(|entry| entry["summary"].as_str())
        .find(|summary| summary.starts_with("[openrouter error]"))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    #[test]
    fn error_diagnostic_finds_openrouter_thought_entry() {
        let transcript = json!({
            "entries": [
                {
                    "kind": "agent_thought",
                    "summary": "[openrouter error] provider rejected request"
                },
                {
                    "kind": "assistant_text",
                    "summary": "partial response"
                }
            ]
        });

        assert_eq!(
            super::error_diagnostic(&transcript),
            Some("[openrouter error] provider rejected request")
        );
    }

    #[test]
    fn error_diagnostic_ignores_successful_transcript() {
        let transcript = json!({
            "entries": [
                {
                    "kind": "assistant_text",
                    "summary": "complete response"
                }
            ]
        });

        assert_eq!(super::error_diagnostic(&transcript), None);
    }
}
