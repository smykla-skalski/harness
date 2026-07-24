//! Daemon-owned working-copy registry for task-board delivery.
//!
//! When an imported task-board item references a repository that is not
//! checked out anywhere on the machine, the user has no local folder to
//! point delivery at. This subsystem lets the daemon obtain a real working
//! copy (a full checkout, unlike the bare/blobless reviews clone) into its
//! own sandbox-writable data root and hand back the path, which the app then
//! forwards as the session `project_dir`.
//!
//! This module owns the on-disk layout and the persisted registry:
//!
//! - [`WorkingCopyKey`] (sha256-prefixed `owner/name`) + [`WorkingCopyRoot`]
//!   (filesystem layout under `<daemon-root>/task_board/working-copies`).
//! - [`WorkingCopyRegistry`] (persisted as `registry.json`) with serde plus
//!   the two-pass GC selection (drop stale, then LRU-evict over budget).
//! - [`WorkingCopyListEntry`], the Settings/sheet projection that also
//!   carries the checkout `path` so the app can forward it as `project_dir`.
//!
//! The git operations live in [`runtime`]; the progress-to-WebSocket bridge
//! lives in [`progress`].

pub mod progress;
pub mod runtime;

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Default disk budget (MB) for the whole working-copies tree. A full
/// checkout is materially larger than a bare clone, so the budget is smaller
/// than the reviews clone budget: a working copy is a convenience the user
/// can always re-obtain, not a cache we must retain.
pub const WORKING_COPY_DISK_BUDGET_MB: u64 = 3 * 1024;

/// Default age beyond which an unused working copy is evicted.
pub const WORKING_COPY_MAX_AGE_DAYS: i64 = 14;

/// Stable, filesystem-safe identifier for one working copy. Two repos with
/// the same name under different owners (forks) do not collide because the
/// 8-char hash is computed from the full `owner/name` slug.
///
/// Serialized as the raw `owner/name` string so the registry on disk can use
/// it as a JSON object key.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WorkingCopyKey {
    /// `owner/name` slug as GitHub returns it from `nameWithOwner`.
    pub repo_full_name: String,
}

impl WorkingCopyKey {
    #[must_use]
    pub fn new(repo_full_name: impl Into<String>) -> Self {
        Self {
            repo_full_name: repo_full_name.into(),
        }
    }

    /// 8-char lowercase-hex sha256 prefix used in the on-disk segment so
    /// different owners with the same repo name don't collide.
    #[must_use]
    pub fn segment_prefix(&self) -> String {
        let mut hasher = Sha256::new();
        hasher.update(self.repo_full_name.as_bytes());
        let digest = hasher.finalize();
        digest.iter().take(4).fold(String::new(), |mut acc, b| {
            let _ = write!(acc, "{b:02x}");
            acc
        })
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
                _ => '_',
            })
            .collect();
        if safe.len() > 96 {
            safe.truncate(96);
        }
        format!("{prefix}__{safe}")
    }

    /// On-disk path to the working-copy directory (the checkout root that
    /// contains a `.git` subdirectory) under `working_copies_root`. Unlike
    /// the reviews bare clone there is no `.git` suffix - this is a full
    /// working tree, valid as a session `origin`.
    #[must_use]
    pub fn checkout_path(&self, working_copies_root: &Path) -> PathBuf {
        working_copies_root.join(self.safe_segment())
    }
}

/// Filesystem layout root for the working-copy subsystem.
#[derive(Debug, Clone)]
pub struct WorkingCopyRoot {
    pub path: PathBuf,
}

impl WorkingCopyRoot {
    #[must_use]
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    #[must_use]
    pub fn registry_path(&self) -> PathBuf {
        self.path.join("registry.json")
    }
}

/// One row inside `registry.json` describing a known working copy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkingCopyRegistryEntry {
    pub repo_full_name: String,
    pub checkout_path: PathBuf,
    pub size_bytes: u64,
    pub created_at: DateTime<Utc>,
    pub last_used_at: DateTime<Utc>,
}

/// Persisted registry of all known working copies.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkingCopyRegistry {
    #[serde(default)]
    pub entries: BTreeMap<WorkingCopyKey, WorkingCopyRegistryEntry>,
}

impl WorkingCopyRegistry {
    #[must_use]
    pub fn total_size_bytes(&self) -> u64 {
        self.entries.values().map(|e| e.size_bytes).sum()
    }

    pub fn touch(&mut self, key: &WorkingCopyKey, now: DateTime<Utc>) {
        if let Some(entry) = self.entries.get_mut(key) {
            entry.last_used_at = now;
        }
    }

    pub fn insert_or_update(&mut self, key: WorkingCopyKey, entry: WorkingCopyRegistryEntry) {
        self.entries.insert(key, entry);
    }

    pub fn remove(&mut self, key: &WorkingCopyKey) -> Option<WorkingCopyRegistryEntry> {
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
    ) -> Vec<WorkingCopyKey> {
        let age_targets: BTreeSet<WorkingCopyKey> = self
            .entries
            .iter()
            .filter(|(_, entry)| now.signed_duration_since(entry.last_used_at) > max_age)
            .map(|(key, _)| key.clone())
            .collect();

        let mut remaining: Vec<(&WorkingCopyKey, &WorkingCopyRegistryEntry)> = self
            .entries
            .iter()
            .filter(|(key, _)| !age_targets.contains(*key))
            .collect();
        // Oldest last_used_at first, so LRU eviction drops the stalest.
        remaining.sort_by_key(|(_, entry)| entry.last_used_at);

        let mut targets: Vec<WorkingCopyKey> = age_targets.into_iter().collect();
        let mut remaining_size: u64 = remaining.iter().map(|(_, entry)| entry.size_bytes).sum();
        for (key, entry) in remaining {
            if remaining_size <= max_disk_bytes {
                break;
            }
            remaining_size = remaining_size.saturating_sub(entry.size_bytes);
            targets.push(key.clone());
        }
        targets
    }
}

/// One row in the Settings/sheet projection of the working-copy registry.
/// Carries the checkout `path` because the app forwards it verbatim as the
/// session `project_dir`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct WorkingCopyListEntry {
    pub repo_full_name: String,
    pub repo_key_segment: String,
    pub path: String,
    pub size_bytes: u64,
    #[cfg_attr(feature = "openapi", schema(value_type = String, format = DateTime))]
    pub created_at: DateTime<Utc>,
    #[cfg_attr(feature = "openapi", schema(value_type = String, format = DateTime))]
    pub last_used_at: DateTime<Utc>,
}

impl WorkingCopyListEntry {
    #[must_use]
    pub fn from_registry_entry(key: &WorkingCopyKey, entry: &WorkingCopyRegistryEntry) -> Self {
        Self {
            repo_full_name: entry.repo_full_name.clone(),
            repo_key_segment: key.safe_segment(),
            path: entry.checkout_path.to_string_lossy().into_owned(),
            size_bytes: entry.size_bytes,
            created_at: entry.created_at,
            last_used_at: entry.last_used_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(now: DateTime<Utc>, size: u64) -> WorkingCopyRegistryEntry {
        WorkingCopyRegistryEntry {
            repo_full_name: "owner/repo".into(),
            checkout_path: PathBuf::from("/tmp/working-copies/x"),
            size_bytes: size,
            created_at: now,
            last_used_at: now,
        }
    }

    #[test]
    fn key_segment_prefix_is_8_hex_chars() {
        let key = WorkingCopyKey::new("owner/repo");
        let prefix = key.segment_prefix();
        assert_eq!(prefix.len(), 8);
        assert!(prefix.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn key_segment_prefix_differs_across_repos() {
        let a = WorkingCopyKey::new("owner/repo").segment_prefix();
        let b = WorkingCopyKey::new("other/repo").segment_prefix();
        assert_ne!(a, b);
    }

    #[test]
    fn key_safe_segment_sanitizes_slashes() {
        let key = WorkingCopyKey::new("owner-1/My.Repo_v2");
        let segment = key.safe_segment();
        assert!(segment.contains("owner-1_My.Repo_v2"));
        assert!(!segment.contains('/'));
        assert!(segment.contains("__"));
    }

    #[test]
    fn key_checkout_path_has_no_git_suffix() {
        let key = WorkingCopyKey::new("owner/repo");
        let root = Path::new("/tmp/working-copies");
        let path = key.checkout_path(root);
        assert!(!path.to_string_lossy().ends_with(".git"));
        assert!(path.starts_with(root));
    }

    #[test]
    fn root_registry_path() {
        let root = WorkingCopyRoot::new(PathBuf::from("/tmp/working-copies"));
        assert_eq!(
            root.registry_path(),
            PathBuf::from("/tmp/working-copies/registry.json")
        );
    }

    #[test]
    fn registry_total_size_sums_entries() {
        let mut registry = WorkingCopyRegistry::default();
        let now = Utc::now();
        registry.insert_or_update(WorkingCopyKey::new("a/r"), make_entry(now, 100));
        registry.insert_or_update(WorkingCopyKey::new("b/r"), make_entry(now, 200));
        assert_eq!(registry.total_size_bytes(), 300);
    }

    #[test]
    fn registry_touch_updates_last_used_at() {
        let mut registry = WorkingCopyRegistry::default();
        let then = Utc::now() - Duration::hours(2);
        let key = WorkingCopyKey::new("a/r");
        registry.insert_or_update(key.clone(), make_entry(then, 100));
        let now = Utc::now();
        registry.touch(&key, now);
        assert_eq!(registry.entries.get(&key).expect("present").last_used_at, now);
    }

    #[test]
    fn registry_gc_drops_entries_older_than_max_age() {
        let mut registry = WorkingCopyRegistry::default();
        let now = Utc::now();
        let old_key = WorkingCopyKey::new("old/r");
        let mut old_entry = make_entry(now, 100);
        old_entry.last_used_at = now - Duration::days(40);
        registry.insert_or_update(old_key.clone(), old_entry);
        registry.insert_or_update(WorkingCopyKey::new("fresh/r"), make_entry(now, 100));

        let targets = registry.pick_gc_targets(now, Duration::days(14), 10_000);
        assert_eq!(targets, vec![old_key]);
    }

    #[test]
    fn registry_gc_evicts_lru_until_under_disk_budget() {
        let mut registry = WorkingCopyRegistry::default();
        let now = Utc::now();
        let oldest = WorkingCopyKey::new("a/oldest");
        let mut oldest_entry = make_entry(now, 1_000);
        oldest_entry.last_used_at = now - Duration::hours(48);
        registry.insert_or_update(oldest.clone(), oldest_entry);
        let middle = WorkingCopyKey::new("b/middle");
        let mut middle_entry = make_entry(now, 1_000);
        middle_entry.last_used_at = now - Duration::hours(24);
        registry.insert_or_update(middle.clone(), middle_entry);
        let newest = WorkingCopyKey::new("c/newest");
        registry.insert_or_update(newest.clone(), make_entry(now, 1_000));

        let targets = registry.pick_gc_targets(now, Duration::days(30), 1_500);
        assert_eq!(targets.len(), 2);
        assert!(targets.contains(&oldest));
        assert!(targets.contains(&middle));
        assert!(!targets.contains(&newest));
    }

    #[test]
    fn registry_gc_returns_empty_when_under_budget_and_fresh() {
        let mut registry = WorkingCopyRegistry::default();
        let now = Utc::now();
        registry.insert_or_update(WorkingCopyKey::new("a/r"), make_entry(now, 100));
        registry.insert_or_update(WorkingCopyKey::new("b/r"), make_entry(now, 100));
        assert!(
            registry
                .pick_gc_targets(now, Duration::days(14), 1_000)
                .is_empty()
        );
    }

    #[test]
    fn list_entry_projects_registry_row_with_path() {
        let key = WorkingCopyKey::new("owner/repo");
        let now = Utc::now();
        let entry = make_entry(now, 4_096);
        let list_entry = WorkingCopyListEntry::from_registry_entry(&key, &entry);
        assert_eq!(list_entry.repo_full_name, "owner/repo");
        assert_eq!(list_entry.size_bytes, 4_096);
        assert_eq!(list_entry.path, "/tmp/working-copies/x");
        assert!(list_entry.repo_key_segment.contains("owner_repo"));
    }

    #[test]
    fn registry_serde_round_trip() {
        let mut registry = WorkingCopyRegistry::default();
        registry.insert_or_update(WorkingCopyKey::new("a/r"), make_entry(Utc::now(), 100));
        let json = serde_json::to_string(&registry).expect("serialize");
        let parsed: WorkingCopyRegistry = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed.entries.len(), 1);
    }

    #[test]
    fn registry_remove_drops_entry() {
        let mut registry = WorkingCopyRegistry::default();
        let key = WorkingCopyKey::new("a/r");
        registry.insert_or_update(key.clone(), make_entry(Utc::now(), 100));
        assert!(registry.remove(&key).is_some());
        assert!(!registry.entries.contains_key(&key));
    }
}
