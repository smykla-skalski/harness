use serde::{Deserialize, Serialize};

/// Immutable metadata for a run, stored in run-metadata.json.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunMetadata {
    pub run_id: String,
    pub suite_id: String,
    pub suite_path: String,
    pub suite_dir: String,
    pub profile: String,
    pub repo_root: String,
    #[serde(default)]
    pub keep_clusters: bool,
    pub created_at: String,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
}
