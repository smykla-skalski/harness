use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use super::wire::{RemoteWireError, require_digest};

const MAX_MANIFEST_ENTRIES: usize = 64;
pub(crate) const MAX_REMOTE_ARTIFACT_BYTES: u64 = 32 * 1024 * 1024;
pub(super) const MAX_REMOTE_ARTIFACT_BYTES_USIZE: usize = 32 * 1024 * 1024;
const MAX_MANIFEST_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ARTIFACT_PATH_BYTES: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteArtifactEntry {
    pub(crate) relative_path: String,
    pub(crate) sha256: String,
    pub(crate) size_bytes: u64,
    pub(crate) media_type: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteArtifactManifest {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) entries: Vec<RemoteArtifactEntry>,
}

impl RemoteArtifactManifest {
    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        if self.entries.len() > MAX_MANIFEST_ENTRIES {
            return Err(RemoteWireError::InvalidManifest);
        }
        let mut paths = BTreeSet::new();
        let mut total = 0_u64;
        for entry in &self.entries {
            if !valid_artifact_path(&entry.relative_path)
                || !paths.insert(entry.relative_path.as_str())
                || entry.size_bytes > MAX_REMOTE_ARTIFACT_BYTES
                || entry.media_type.trim().is_empty()
                || require_digest("artifact_sha256", &entry.sha256).is_err()
            {
                return Err(RemoteWireError::InvalidManifest);
            }
            total = total
                .checked_add(entry.size_bytes)
                .ok_or(RemoteWireError::InvalidManifest)?;
            if total > MAX_MANIFEST_BYTES {
                return Err(RemoteWireError::InvalidManifest);
            }
        }
        Ok(())
    }
}

pub(super) fn valid_artifact_path(path: &str) -> bool {
    if path.is_empty() || path.len() > MAX_ARTIFACT_PATH_BYTES || path.starts_with('/') {
        return false;
    }
    path.split('/').all(|component| {
        !component.is_empty()
            && component != "."
            && component != ".."
            && component
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    })
}
