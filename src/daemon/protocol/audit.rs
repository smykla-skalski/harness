use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HarnessMonitorAuditDateRange {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HarnessMonitorAuditEventsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date_range: Option<HarnessMonitorAuditDateRange>,
    #[serde(default)]
    pub sources: Vec<String>,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub severities: Vec<String>,
    #[serde(default)]
    pub outcomes: Vec<String>,
    #[serde(default)]
    pub action_keys: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_text: Option<String>,
}

impl HarnessMonitorAuditEventsRequest {
    #[must_use]
    pub const fn default_limit() -> u32 {
        100
    }

    #[must_use]
    pub fn normalized_limit(&self) -> u32 {
        self.limit
            .unwrap_or(Self::default_limit())
            .clamp(1, Self::max_limit())
    }

    #[must_use]
    pub const fn max_limit() -> u32 {
        500
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HarnessMonitorAuditEvent {
    pub id: String,
    pub recorded_at: String,
    pub source: String,
    pub category: String,
    pub kind: String,
    pub severity: String,
    pub outcome: String,
    pub title: String,
    pub summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload_json: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_message: Option<String>,
    #[serde(default)]
    pub related_urls: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HarnessMonitorAuditEventsResponse {
    pub events: Vec<HarnessMonitorAuditEvent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
    pub has_older: bool,
}
