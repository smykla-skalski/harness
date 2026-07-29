use serde::{Deserialize, Serialize};

/// Provider-neutral reason an agent turn did not complete successfully.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AgentTurnFailureCategory {
    ProviderRejected,
    Authentication,
    RateLimited,
    UnsupportedModel,
    Transport,
    Cancelled,
    Unknown,
}

impl AgentTurnFailureCategory {
    #[must_use]
    pub const fn automatic_retry_safe(self) -> bool {
        matches!(self, Self::RateLimited)
    }

    #[must_use]
    pub fn from_message(message: &str) -> Self {
        let message = message.to_ascii_lowercase();
        if contains_any(
            &message,
            &[
                "authentication",
                "unauthorized",
                "invalid api key",
                "sign in",
                "login required",
                "http 401",
            ],
        ) {
            Self::Authentication
        } else if contains_any(&message, &["rate limit", "too many requests", "http 429"]) {
            Self::RateLimited
        } else if contains_any(
            &message,
            &["unsupported model", "unknown model", "model not found"],
        ) || message.contains("model") && message.contains("does not accept")
        {
            Self::UnsupportedModel
        } else if contains_any(
            &message,
            &[
                "transport",
                "connection closed",
                "connection reset",
                "broken pipe",
                "timed out",
                "timeout",
                "unexpected eof",
                "stream ended",
            ],
        ) {
            Self::Transport
        } else if contains_any(
            &message,
            &["rejected", "refused", "moderation", "policy block"],
        ) {
            Self::ProviderRejected
        } else {
            Self::Unknown
        }
    }
}

fn contains_any(message: &str, patterns: &[&str]) -> bool {
    patterns.iter().any(|pattern| message.contains(pattern))
}

/// Shared lifecycle boundary where a turn failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum AgentTurnFailureStage {
    Start,
    Execution,
    Cancellation,
}

impl AgentTurnFailureStage {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Execution => "execution",
            Self::Cancellation => "cancellation",
        }
    }
}

/// Structured terminal failure used by every agent runtime.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct AgentTurnFailure {
    pub category: AgentTurnFailureCategory,
    pub stage: AgentTurnFailureStage,
    pub automatic_retry_safe: bool,
    pub detail: String,
}

impl AgentTurnFailure {
    #[must_use]
    pub fn new(
        category: AgentTurnFailureCategory,
        stage: AgentTurnFailureStage,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            category,
            stage,
            automatic_retry_safe: category.automatic_retry_safe(),
            detail: detail.into(),
        }
    }

    #[must_use]
    pub fn cancelled(detail: impl Into<String>) -> Self {
        Self::new(
            AgentTurnFailureCategory::Cancelled,
            AgentTurnFailureStage::Cancellation,
            detail,
        )
    }

    #[must_use]
    pub fn unknown(stage: AgentTurnFailureStage, detail: impl Into<String>) -> Self {
        Self::new(AgentTurnFailureCategory::Unknown, stage, detail)
    }
}

#[cfg(test)]
mod tests {
    use super::{AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage};

    #[test]
    fn retry_safety_is_part_of_the_wire_contract() {
        let failure = AgentTurnFailure::new(
            AgentTurnFailureCategory::Transport,
            AgentTurnFailureStage::Execution,
            "connection closed",
        );

        assert!(!failure.automatic_retry_safe);
        assert_eq!(
            serde_json::to_value(failure).expect("serialize failure"),
            serde_json::json!({
                "category": "transport",
                "stage": "execution",
                "automatic_retry_safe": false,
                "detail": "connection closed",
            })
        );
    }

    #[test]
    fn unsafe_categories_never_request_automatic_retry() {
        for category in [
            AgentTurnFailureCategory::ProviderRejected,
            AgentTurnFailureCategory::Authentication,
            AgentTurnFailureCategory::UnsupportedModel,
            AgentTurnFailureCategory::Transport,
            AgentTurnFailureCategory::Cancelled,
            AgentTurnFailureCategory::Unknown,
        ] {
            assert!(!category.automatic_retry_safe(), "{category:?}");
        }
    }

    #[test]
    fn equivalent_provider_messages_share_categories() {
        let cases = [
            (
                "HTTP 401 unauthorized",
                AgentTurnFailureCategory::Authentication,
            ),
            ("too many requests", AgentTurnFailureCategory::RateLimited),
            (
                "unsupported model gpt-x",
                AgentTurnFailureCategory::UnsupportedModel,
            ),
            ("connection closed", AgentTurnFailureCategory::Transport),
            (
                "provider refused the prompt",
                AgentTurnFailureCategory::ProviderRejected,
            ),
            ("something new", AgentTurnFailureCategory::Unknown),
        ];

        for (message, expected) in cases {
            assert_eq!(AgentTurnFailureCategory::from_message(message), expected);
        }
    }
}
