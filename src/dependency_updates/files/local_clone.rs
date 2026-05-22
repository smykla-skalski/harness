//! Local bare-clone registry for the substantial-PR diff strategy.
//!
//! When a PR's total churn exceeds the configured threshold (default 500
//! lines), the daemon clones the repo locally as a bare partial clone
//! (`--filter=blob:none --no-tags`) and computes the diff via `git diff`
//! offline. This avoids GitHub's REST patch truncation and consumes zero
//! HTTP rate-limit budget.
//!
//! This module owns:
//!
//! - `RepoKey` (sha256-prefixed owner/name) + `LocalCloneRoot` (filesystem
//!   layout)
//! - `LocalCloneRegistry` (persisted as `registry.json`) with serde + LRU
//!   selection logic.
//! - `Sensitive<String>` PAT wrapper that masks Debug to prevent leakage in
//!   tracing spans.
//! - GC selection: drop entries older than `max_age_days` then LRU-evict
//!   until under `max_disk_bytes`.
//! - `LocalCloneListEntry` projection used by the Settings panel.
//!
//! The actual git operations and per-RepoKey mutex live in
//! `local_clone_runtime`; diff rendering lives in `local_clone_runtime::diff`.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Default disk budget (MB) for the entire clones tree.
pub(crate) const LOCAL_CLONE_DISK_BUDGET_MB: u64 = 5 * 1024;

/// Default age beyond which an unused clone is evicted.
pub(crate) const LOCAL_CLONE_MAX_AGE_DAYS: i64 = 30;

/// Stable, filesystem-safe identifier for one cloned repo. Two repos with
/// the same name under different orgs (forks) do not collide because the
/// 8-char hash is computed from the full `owner/name` slug.
///
/// Serialized as the raw `owner/name` string so the registry on disk can use
/// it as a JSON object key.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RepoKey {
    /// `owner/name` slug as GitHub returns it from `nameWithOwner`.
    pub repo_full_name: String,
}

impl RepoKey {
    #[must_use]
    pub fn new(repo_full_name: impl Into<String>) -> Self {
        Self {
            repo_full_name: repo_full_name.into(),
        }
    }

    /// 8-char lowercase-hex sha256 prefix used in the on-disk segment so
    /// different orgs with same repo name don't collide.
    #[must_use]
    pub fn segment_prefix(&self) -> String {
        let mut hasher = Sha256::new();
        hasher.update(self.repo_full_name.as_bytes());
        let digest = hasher.finalize();
        digest.iter().take(4).map(|b| format!("{b:02x}")).collect()
    }

    /// Sanitized owner+name segment safe for filesystem use.
    #[must_use]
    pub fn safe_segment(&self) -> String {
        let prefix = self.segment_prefix();
        let mut safe: String = self
            .repo_full_name
            .chars()
            .map(|c| match c {
                'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => c,
                '/' => '_',
                _ => '_',
            })
            .collect();
        if safe.len() > 96 {
            safe.truncate(96);
        }
        format!("{prefix}__{safe}")
    }

    /// On-disk path to the bare clone directory under `clones_root`.
    #[must_use]
    pub fn bare_path(&self, clones_root: &Path) -> PathBuf {
        clones_root.join(format!("{}.git", self.safe_segment()))
    }
}

/// Filesystem layout root for the local-clone subsystem.
#[derive(Debug, Clone)]
pub struct LocalCloneRoot {
    pub path: PathBuf,
}

impl LocalCloneRoot {
    #[must_use]
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    #[must_use]
    pub fn registry_path(&self) -> PathBuf {
        self.path.join("registry.json")
    }
}

/// One row inside `registry.json` describing a known clone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryEntry {
    pub repo_full_name: String,
    pub bare_path: PathBuf,
    pub size_bytes: u64,
    pub created_at: DateTime<Utc>,
    pub last_used_at: DateTime<Utc>,
    pub last_fetched_at: DateTime<Utc>,
    #[serde(default)]
    pub last_known_head_ref_oid_by_pr: BTreeMap<u64, String>,
}

/// Persisted registry of all known local clones.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalCloneRegistry {
    #[serde(default)]
    pub entries: BTreeMap<RepoKey, RegistryEntry>,
}

impl LocalCloneRegistry {
    #[must_use]
    pub fn total_size_bytes(&self) -> u64 {
        self.entries.values().map(|e| e.size_bytes).sum()
    }

    pub fn touch(&mut self, key: &RepoKey, now: DateTime<Utc>) {
        if let Some(entry) = self.entries.get_mut(key) {
            entry.last_used_at = now;
        }
    }

    pub fn insert_or_update(&mut self, key: RepoKey, entry: RegistryEntry) {
        self.entries.insert(key, entry);
    }

    pub fn remove(&mut self, key: &RepoKey) -> Option<RegistryEntry> {
        self.entries.remove(key)
    }

    /// Decide which entries to garbage-collect. Runs in two passes:
    ///
    /// 1. Drop entries whose `last_used_at` is older than `max_age`.
    /// 2. If total size is still above `max_disk_bytes`, drop LRU entries
    ///    until under budget.
    pub fn pick_gc_targets(
        &self,
        now: DateTime<Utc>,
        max_age: Duration,
        max_disk_bytes: u64,
    ) -> Vec<RepoKey> {
        let mut age_targets: Vec<RepoKey> = self
            .entries
            .iter()
            .filter(|(_, entry)| now.signed_duration_since(entry.last_used_at) > max_age)
            .map(|(key, _)| key.clone())
            .collect();

        let mut remaining: Vec<(RepoKey, RegistryEntry)> = self
            .entries
            .iter()
            .filter(|(key, _)| !age_targets.contains(key))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        // Oldest last_used_at first.
        remaining.sort_by(|a, b| a.1.last_used_at.cmp(&b.1.last_used_at));

        let mut remaining_size: u64 = remaining.iter().map(|(_, e)| e.size_bytes).sum();
        let mut lru_targets: Vec<RepoKey> = Vec::new();
        while remaining_size > max_disk_bytes && !remaining.is_empty() {
            let (key, entry) = remaining.remove(0);
            remaining_size = remaining_size.saturating_sub(entry.size_bytes);
            lru_targets.push(key);
        }

        age_targets.extend(lru_targets);
        age_targets
    }
}

/// Wrapper around a secret string (typically a GitHub PAT) whose `Debug`
/// impl masks the contents so `tracing` spans don't accidentally leak the
/// token to logs.
#[derive(Clone)]
pub struct Sensitive(String);

impl Sensitive {
    #[must_use]
    pub fn new(secret: impl Into<String>) -> Self {
        Self(secret.into())
    }

    #[must_use]
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Sensitive {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Sensitive(<redacted {} chars>)", self.0.len())
    }
}

impl fmt::Display for Sensitive {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "<redacted>")
    }
}

/// Build the GitHub HTTPS clone URL with PAT injection. The returned string
/// is only suitable for passing to `git clone` / `git fetch`; never log it.
#[must_use]
pub fn pat_clone_url(repo_full_name: &str, token: &Sensitive) -> Sensitive {
    Sensitive::new(format!(
        "https://x-access-token:{}@github.com/{}.git",
        token.expose(),
        repo_full_name
    ))
}

/// One row in the Settings-panel projection of the clones registry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalCloneListEntry {
    pub repo_full_name: String,
    pub repo_key_segment: String,
    pub size_bytes: u64,
    pub created_at: DateTime<Utc>,
    pub last_used_at: DateTime<Utc>,
    pub last_fetched_at: DateTime<Utc>,
}

impl LocalCloneListEntry {
    #[must_use]
    pub fn from_registry_entry(key: &RepoKey, entry: &RegistryEntry) -> Self {
        Self {
            repo_full_name: entry.repo_full_name.clone(),
            repo_key_segment: key.safe_segment(),
            size_bytes: entry.size_bytes,
            created_at: entry.created_at,
            last_used_at: entry.last_used_at,
            last_fetched_at: entry.last_fetched_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(now: DateTime<Utc>, size: u64) -> RegistryEntry {
        RegistryEntry {
            repo_full_name: "owner/repo".into(),
            bare_path: PathBuf::from("/tmp/clones/x.git"),
            size_bytes: size,
            created_at: now,
            last_used_at: now,
            last_fetched_at: now,
            last_known_head_ref_oid_by_pr: BTreeMap::new(),
        }
    }

    #[test]
    fn repo_key_segment_prefix_is_8_hex_chars() {
        let key = RepoKey::new("owner/repo");
        let prefix = key.segment_prefix();
        assert_eq!(prefix.len(), 8);
        assert!(prefix.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn repo_key_segment_prefix_differs_across_repos() {
        let a = RepoKey::new("owner/repo").segment_prefix();
        let b = RepoKey::new("other/repo").segment_prefix();
        assert_ne!(a, b);
    }

    #[test]
    fn repo_key_safe_segment_sanitizes_slashes() {
        let key = RepoKey::new("owner-1/My.Repo_v2");
        let segment = key.safe_segment();
        // Owner with hyphen, repo with dot+underscore, slash becomes underscore.
        assert!(segment.contains("owner-1_My.Repo_v2"));
        assert!(!segment.contains('/'));
        assert!(segment.contains("__")); // separator between prefix and name
    }

    #[test]
    fn repo_key_safe_segment_truncates_long_names() {
        let long_name = format!("owner/{}", "a".repeat(200));
        let key = RepoKey::new(long_name);
        let segment = key.safe_segment();
        // 8 prefix + 2 separator + up to 96 chars.
        assert!(segment.len() <= 110);
    }

    #[test]
    fn repo_key_bare_path_uses_git_suffix() {
        let key = RepoKey::new("owner/repo");
        let root = Path::new("/tmp/clones");
        let path = key.bare_path(root);
        assert!(path.to_string_lossy().ends_with(".git"));
    }

    #[test]
    fn local_clone_root_registry_path() {
        let root = LocalCloneRoot::new(PathBuf::from("/tmp/clones"));
        let registry_path = root.registry_path();
        assert_eq!(registry_path, PathBuf::from("/tmp/clones/registry.json"));
    }

    #[test]
    fn sensitive_debug_redacts() {
        let token = Sensitive::new("ghp_topsecret");
        let debug = format!("{token:?}");
        assert!(!debug.contains("ghp_topsecret"));
        assert!(debug.contains("redacted"));
    }

    #[test]
    fn sensitive_display_redacts() {
        let token = Sensitive::new("ghp_topsecret");
        let display = format!("{token}");
        assert!(!display.contains("ghp_topsecret"));
    }

    #[test]
    fn sensitive_expose_returns_inner() {
        let token = Sensitive::new("ghp_topsecret");
        assert_eq!(token.expose(), "ghp_topsecret");
    }

    #[test]
    fn pat_clone_url_includes_token_and_repo() {
        let token = Sensitive::new("ghp_abc");
        let url = pat_clone_url("owner/repo", &token);
        let url_str = url.expose();
        assert!(url_str.contains("ghp_abc"));
        assert!(url_str.contains("owner/repo.git"));
        assert!(url_str.starts_with("https://x-access-token:"));
        // Sensitive wrapper still masks Debug for the URL itself.
        let debug = format!("{url:?}");
        assert!(!debug.contains("ghp_abc"));
    }

    #[test]
    fn registry_total_size_sums_entries() {
        let mut registry = LocalCloneRegistry::default();
        let now = Utc::now();
        registry.insert_or_update(RepoKey::new("a/r"), make_entry(now, 100));
        registry.insert_or_update(RepoKey::new("b/r"), make_entry(now, 200));
        assert_eq!(registry.total_size_bytes(), 300);
    }

    #[test]
    fn registry_touch_updates_last_used_at() {
        let mut registry = LocalCloneRegistry::default();
        let then = Utc::now() - Duration::hours(2);
        let key = RepoKey::new("a/r");
        registry.insert_or_update(key.clone(), make_entry(then, 100));
        let now = Utc::now();
        registry.touch(&key, now);
        let entry = registry.entries.get(&key).expect("present");
        assert_eq!(entry.last_used_at, now);
    }

    #[test]
    fn registry_gc_drops_entries_older_than_max_age() {
        let mut registry = LocalCloneRegistry::default();
        let now = Utc::now();
        let old_key = RepoKey::new("old/r");
        let mut old_entry = make_entry(now - Duration::days(60), 100);
        old_entry.last_used_at = now - Duration::days(40);
        registry.insert_or_update(old_key.clone(), old_entry);

        let fresh_key = RepoKey::new("fresh/r");
        registry.insert_or_update(fresh_key.clone(), make_entry(now, 100));

        let targets = registry.pick_gc_targets(now, Duration::days(30), 10_000);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0], old_key);
    }

    #[test]
    fn registry_gc_evicts_lru_until_under_disk_budget() {
        let mut registry = LocalCloneRegistry::default();
        let now = Utc::now();
        let oldest_key = RepoKey::new("a/oldest");
        let mut oldest_entry = make_entry(now, 1_000);
        oldest_entry.last_used_at = now - Duration::hours(48);
        registry.insert_or_update(oldest_key.clone(), oldest_entry);

        let middle_key = RepoKey::new("b/middle");
        let mut middle_entry = make_entry(now, 1_000);
        middle_entry.last_used_at = now - Duration::hours(24);
        registry.insert_or_update(middle_key.clone(), middle_entry);

        let newest_key = RepoKey::new("c/newest");
        registry.insert_or_update(newest_key.clone(), make_entry(now, 1_000));

        // Budget 1500 bytes; we have 3000. Need to drop 2 entries (oldest +
        // middle, leaving newest).
        let targets = registry.pick_gc_targets(now, Duration::days(30), 1_500);
        assert_eq!(targets.len(), 2);
        assert!(targets.contains(&oldest_key));
        assert!(targets.contains(&middle_key));
        assert!(!targets.contains(&newest_key));
    }

    #[test]
    fn registry_gc_returns_empty_when_under_budget_and_fresh() {
        let mut registry = LocalCloneRegistry::default();
        let now = Utc::now();
        registry.insert_or_update(RepoKey::new("a/r"), make_entry(now, 100));
        registry.insert_or_update(RepoKey::new("b/r"), make_entry(now, 100));
        let targets = registry.pick_gc_targets(now, Duration::days(30), 1_000);
        assert!(targets.is_empty());
    }

    #[test]
    fn list_entry_projects_registry_row() {
        let key = RepoKey::new("owner/repo");
        let now = Utc::now();
        let entry = make_entry(now, 4_096);
        let list_entry = LocalCloneListEntry::from_registry_entry(&key, &entry);
        assert_eq!(list_entry.repo_full_name, "owner/repo");
        assert_eq!(list_entry.size_bytes, 4_096);
        assert!(list_entry.repo_key_segment.contains("owner_repo"));
    }

    #[test]
    fn registry_serde_round_trip() {
        let mut registry = LocalCloneRegistry::default();
        let now = Utc::now();
        registry.insert_or_update(RepoKey::new("a/r"), make_entry(now, 100));
        let json = serde_json::to_string(&registry).expect("serialize");
        let parsed: LocalCloneRegistry = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed.entries.len(), 1);
    }

    #[test]
    fn registry_remove_drops_entry() {
        let mut registry = LocalCloneRegistry::default();
        let key = RepoKey::new("a/r");
        registry.insert_or_update(key.clone(), make_entry(Utc::now(), 100));
        assert!(registry.entries.contains_key(&key));
        registry.remove(&key);
        assert!(!registry.entries.contains_key(&key));
    }
}
