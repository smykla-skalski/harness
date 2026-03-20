use serde::{Deserialize, Serialize};

use crate::kernel::topology::ClusterSpec;

use super::{RunLayout, RunMetadata};

/// Persisted current run pointer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CurrentRunPointer {
    pub layout: RunLayout,
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub suite_dir: Option<String>,
    #[serde(default)]
    pub suite_id: Option<String>,
    #[serde(default)]
    pub suite_path: Option<String>,
    #[serde(default)]
    pub cluster: Option<ClusterSpec>,
    #[serde(default)]
    pub keep_clusters: bool,
    #[serde(default)]
    pub user_stories: Vec<String>,
    #[serde(default)]
    pub requires: Vec<String>,
}

pub type CurrentRunRecord = CurrentRunPointer;

impl CurrentRunPointer {
    #[must_use]
    pub fn from_metadata(
        layout: RunLayout,
        metadata: &RunMetadata,
        cluster: Option<ClusterSpec>,
    ) -> Self {
        Self {
            layout,
            profile: Some(metadata.profile.clone()),
            repo_root: Some(metadata.repo_root.clone()),
            suite_dir: Some(metadata.suite_dir.clone()),
            suite_id: Some(metadata.suite_id.clone()),
            suite_path: Some(metadata.suite_path.clone()),
            cluster,
            keep_clusters: metadata.keep_clusters,
            user_stories: metadata.user_stories.clone(),
            requires: metadata.requires.clone(),
        }
    }
}
