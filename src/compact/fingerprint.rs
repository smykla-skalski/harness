use std::borrow::Cow;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};

/// SHA256 fingerprint of a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileFingerprint<'a> {
    pub label: Cow<'a, str>,
    pub path: PathBuf,
    pub exists: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mtime_ns: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<Cow<'a, str>>,
}

impl FileFingerprint<'_> {
    /// Build a fingerprint from a file path on disk.
    #[must_use]
    pub fn from_path(label: &str, path: &Path) -> FileFingerprint<'static> {
        let resolved = path.to_path_buf();
        if !resolved.exists() {
            return FileFingerprint {
                label: Cow::Owned(label.to_string()),
                path: resolved,
                exists: false,
                size: None,
                mtime_ns: None,
                sha256: None,
            };
        }
        let meta = fs::metadata(&resolved).ok();
        let size = meta.as_ref().map(fs::Metadata::len);
        let mtime_ns = meta.as_ref().and_then(|m| {
            m.modified().ok().and_then(|t| {
                t.duration_since(UNIX_EPOCH)
                    .ok()
                    .and_then(|d| u64::try_from(d.as_nanos()).ok())
            })
        });
        let sha256 = file_sha256(&resolved);

        FileFingerprint {
            label: Cow::Owned(label.to_string()),
            path: resolved,
            exists: true,
            size,
            mtime_ns,
            sha256: sha256.map(Cow::Owned),
        }
    }

    /// Check if the fingerprint matches the current state on disk.
    #[must_use]
    pub fn matches_disk(&self) -> bool {
        let meta = fs::metadata(&self.path).ok();
        let exists = meta.is_some();
        if exists != self.exists {
            return false;
        }
        let Some(ref meta) = meta else {
            // Both don't exist - match.
            return true;
        };
        let size = Some(meta.len());
        if size != self.size {
            return false;
        }
        let mtime_ns = meta.modified().ok().and_then(|t| {
            t.duration_since(UNIX_EPOCH)
                .ok()
                .and_then(|d| u64::try_from(d.as_nanos()).ok())
        });
        if mtime_ns != self.mtime_ns {
            return false;
        }
        // mtime + size match - compute SHA256 only as final check.
        let sha256 = file_sha256(&self.path);
        sha256.as_deref() == self.sha256.as_deref()
    }
}

pub(crate) fn file_sha256(path: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    let data = fs::read(path).ok()?;
    let hash = Sha256::digest(&data);
    Some(format!("{hash:x}"))
}
