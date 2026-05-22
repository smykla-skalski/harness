use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesBodyUpdateRequest {
    pub pull_request_id: String,
    pub expected_prior_body_sha256: String,
    pub new_body: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyUpdatesBodyUpdateOutcome {
    Updated,
    BodyDrifted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DependencyUpdatesBodyUpdateResponse {
    pub pull_request_id: String,
    pub outcome: DependencyUpdatesBodyUpdateOutcome,
    pub current_body: String,
    pub current_body_sha256: String,
    pub pr_updated_at: DateTime<Utc>,
    pub fetched_at: String,
}

impl DependencyUpdatesBodyUpdateRequest {
    pub const MAX_BODY_BYTES: usize = 262_144;

    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn normalized_expected_prior_body_sha256(&self) -> String {
        self.expected_prior_body_sha256.trim().to_lowercase()
    }
}
