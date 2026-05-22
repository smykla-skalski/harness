//! On-disk + in-memory cache for fetched file patches.
//!
//! Cache key is `(pull_request_id, head_ref_oid, path_sha)`. When a PR is
//! force-pushed, its `head_ref_oid` changes and the cache key changes - no
//! stale patches will be served. The in-memory layer is a `DashMap` of
//! `Arc<FilesEntry>`; the on-disk layer is a per-file JSON blob under
//! `<runtime>/dependency_updates/patches/<repo>/<pr>/<head>/<path_sha>.json`.
//!
//! This commit ships the pure-data layer: cache-key derivation, on-disk
//! path layout, LRU comparisons, and serde for the JSON envelope. Tokio
//! filesystem wiring + GC scan is folded in by the service handler (A.10).

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{DependencyUpdateFilePatch, DependencyUpdateFileServedBy};

/// Default disk budget for the patch cache (MB). Plan default: 256 MB.
pub(crate) const PATCH_DISK_CACHE_BUDGET_MB: u64 = 256;

/// Soft cap on the in-memory cache to prevent runaway growth when many PRs
/// land at once. LRU evicts when the entry count exceeds this.
pub(crate) const PATCH_MEMORY_CACHE_ENTRIES: usize = 8_192;

/// Composite key for a cached patch entry.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PatchCacheKey {
    pub pull_request_id: String,
    pub head_ref_oid: String,
    pub path: String,
}

impl PatchCacheKey {
    /// SHA-256 of the path, lowercase hex. Used as the on-disk filename so
    /// arbitrary repo paths don't collide with filesystem limitations.
    #[must_use]
    pub fn path_hash(&self) -> String {
        sha256_hex(self.path.as_bytes())
    }

    /// SHA-256 prefix of the PR id - 12 chars is plenty for path-segment
    /// uniqueness across reasonable PR counts.
    #[must_use]
    pub fn pull_request_dir_segment(&self) -> String {
        let hash = sha256_hex(self.pull_request_id.as_bytes());
        hash[..12].to_string()
    }

    /// Compute the on-disk path under a given cache root.
    #[must_use]
    pub fn on_disk_path(&self, root: &Path) -> PathBuf {
        let head_prefix = if self.head_ref_oid.len() >= 12 {
            self.head_ref_oid[..12].to_string()
        } else {
            self.head_ref_oid.clone()
        };
        root.join(self.pull_request_dir_segment())
            .join(&head_prefix)
            .join(format!("{}.json", self.path_hash()))
    }
}

/// On-disk envelope. The cached patch carries provenance + freshness so the
/// service can decide whether to revalidate (ETag) or expire.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PatchCacheEntry {
    pub patch: DependencyUpdateFilePatch,
    pub head_ref_oid: String,
    pub fetched_at: DateTime<Utc>,
    pub last_validated_at: DateTime<Utc>,
    pub served_by: DependencyUpdateFileServedBy,
}

impl PatchCacheEntry {
    /// Returns true if the cached entry's age exceeds `max_age_seconds`.
    #[must_use]
    pub fn is_expired(&self, now: DateTime<Utc>, max_age_seconds: u64) -> bool {
        let age = now.signed_duration_since(self.last_validated_at);
        let max_age = chrono::Duration::seconds(max_age_seconds as i64);
        age > max_age
    }

    /// Returns true if `current_head_ref_oid` differs from the entry's. The
    /// caller should evict on mismatch.
    #[must_use]
    pub fn matches_head(&self, current_head_ref_oid: &str) -> bool {
        self.head_ref_oid
            .eq_ignore_ascii_case(current_head_ref_oid.trim())
    }
}

/// One row in the LRU ordering. The cache state machine sorts entries
/// ascending by `last_validated_at`; oldest entries are evicted first when
/// the budget is exceeded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatchCacheLruRow {
    pub key: PatchCacheKey,
    pub last_validated_at: DateTime<Utc>,
    pub byte_size: u64,
}

impl PartialOrd for PatchCacheLruRow {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for PatchCacheLruRow {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.last_validated_at
            .cmp(&other.last_validated_at)
            .then(self.key.path.cmp(&other.key.path))
    }
}

/// Decide which LRU rows to evict given a budget in bytes. Returns the rows
/// to drop, ordered oldest-first. Caller deletes the corresponding on-disk
/// files.
#[must_use]
pub fn pick_evictions_under_budget(
    rows: &mut Vec<PatchCacheLruRow>,
    budget_bytes: u64,
) -> Vec<PatchCacheLruRow> {
    rows.sort();
    let total: u64 = rows.iter().map(|r| r.byte_size).sum();
    if total <= budget_bytes {
        return Vec::new();
    }
    let mut to_evict = Vec::new();
    let mut running = total;
    while running > budget_bytes {
        if rows.is_empty() {
            break;
        }
        let oldest = rows.remove(0);
        running = running.saturating_sub(oldest.byte_size);
        to_evict.push(oldest);
    }
    to_evict
}

/// Pure helper to compute `sha256_hex` for a byte slice.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dependency_updates::files::DependencyUpdateFileChangeType;

    fn make_key(pr: &str, oid: &str, path: &str) -> PatchCacheKey {
        PatchCacheKey {
            pull_request_id: pr.into(),
            head_ref_oid: oid.into(),
            path: path.into(),
        }
    }

    fn make_entry(oid: &str, fetched_at: DateTime<Utc>) -> PatchCacheEntry {
        PatchCacheEntry {
            patch: DependencyUpdateFilePatch {
                path: "src/lib.rs".into(),
                patch: "@@ -1 +1 @@\n-a\n+b".into(),
                status: DependencyUpdateFileChangeType::Modified,
                additions: 1,
                deletions: 1,
                truncated: false,
                etag: Some(r#""abc123""#.into()),
                served_by: DependencyUpdateFileServedBy::GithubRest,
                fetched_at: fetched_at.to_rfc3339(),
                head_ref_oid: oid.into(),
            },
            head_ref_oid: oid.into(),
            fetched_at,
            last_validated_at: fetched_at,
            served_by: DependencyUpdateFileServedBy::GithubRest,
        }
    }

    #[test]
    fn path_hash_is_stable_lowercase_hex() {
        let key = make_key("PR_1", "abc", "src/lib.rs");
        let hash = key.path_hash();
        assert_eq!(hash.len(), 64);
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
        // Run again - should be deterministic.
        let hash2 = key.path_hash();
        assert_eq!(hash, hash2);
    }

    #[test]
    fn different_paths_produce_different_hashes() {
        let a = make_key("PR_1", "abc", "src/lib.rs").path_hash();
        let b = make_key("PR_1", "abc", "src/main.rs").path_hash();
        assert_ne!(a, b);
    }

    #[test]
    fn pr_dir_segment_is_short_hex() {
        let key = make_key("PR_kwDOABC", "abc", "lib.rs");
        let segment = key.pull_request_dir_segment();
        assert_eq!(segment.len(), 12);
    }

    #[test]
    fn on_disk_path_includes_head_prefix() {
        let key = make_key("PR_1", "abcdef0123456789", "src/lib.rs");
        let root = Path::new("/var/cache");
        let path = key.on_disk_path(root);
        let path_str = path.to_string_lossy();
        assert!(path_str.starts_with("/var/cache/"));
        assert!(path_str.contains("/abcdef012345/"));
        assert!(path_str.ends_with(".json"));
    }

    #[test]
    fn on_disk_path_handles_short_head_oid() {
        let key = make_key("PR_1", "abc", "src/lib.rs");
        let root = Path::new("/var/cache");
        let path = key.on_disk_path(root);
        let path_str = path.to_string_lossy();
        assert!(path_str.contains("/abc/"));
    }

    #[test]
    fn cache_entry_expires_on_age() {
        let now = Utc::now();
        let entry = make_entry("abc", now - chrono::Duration::seconds(3601));
        assert!(entry.is_expired(now, 3600));
    }

    #[test]
    fn cache_entry_fresh_when_within_max_age() {
        let now = Utc::now();
        let entry = make_entry("abc", now - chrono::Duration::seconds(60));
        assert!(!entry.is_expired(now, 3600));
    }

    #[test]
    fn matches_head_is_case_insensitive() {
        let entry = make_entry("ABC123", Utc::now());
        assert!(entry.matches_head("abc123"));
        assert!(entry.matches_head("ABC123"));
        assert!(!entry.matches_head("def456"));
    }

    #[test]
    fn pick_evictions_returns_empty_when_under_budget() {
        let now = Utc::now();
        let mut rows = vec![
            PatchCacheLruRow {
                key: make_key("PR_1", "abc", "a.rs"),
                last_validated_at: now,
                byte_size: 100,
            },
            PatchCacheLruRow {
                key: make_key("PR_1", "abc", "b.rs"),
                last_validated_at: now,
                byte_size: 100,
            },
        ];
        let evictions = pick_evictions_under_budget(&mut rows, 500);
        assert!(evictions.is_empty());
    }

    #[test]
    fn pick_evictions_drops_oldest_first() {
        let now = Utc::now();
        let mut rows = vec![
            PatchCacheLruRow {
                key: make_key("PR_1", "abc", "newest.rs"),
                last_validated_at: now,
                byte_size: 200,
            },
            PatchCacheLruRow {
                key: make_key("PR_1", "abc", "oldest.rs"),
                last_validated_at: now - chrono::Duration::days(2),
                byte_size: 200,
            },
            PatchCacheLruRow {
                key: make_key("PR_1", "abc", "middle.rs"),
                last_validated_at: now - chrono::Duration::hours(1),
                byte_size: 200,
            },
        ];
        let evictions = pick_evictions_under_budget(&mut rows, 250);
        // Oldest first, then middle until we're under budget.
        assert_eq!(evictions.len(), 2);
        assert_eq!(evictions[0].key.path, "oldest.rs");
        assert_eq!(evictions[1].key.path, "middle.rs");
        // newest remains.
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].key.path, "newest.rs");
    }

    #[test]
    fn sha256_hex_is_stable_and_correct_length() {
        let hash = sha256_hex(b"hello");
        assert_eq!(hash.len(), 64);
        assert_eq!(
            hash,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn cache_entry_serde_round_trip() {
        let now = Utc::now();
        let entry = make_entry("abc123", now);
        let json = serde_json::to_string(&entry).expect("serialize");
        let parsed: PatchCacheEntry = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed, entry);
    }
}
