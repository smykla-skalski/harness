use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fs_err as fs;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::daemon::state;

use super::types::GitHubCachePolicy;

const MEMORY_ENTRY_CAP: usize = 512;
#[cfg(not(test))]
const DISK_GC_ENTRY_CAP: usize = 4096;
#[cfg(test)]
const DISK_GC_ENTRY_CAP: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GitHubCacheState {
    Fresh,
    Stale,
}

#[derive(Debug, Clone)]
pub(crate) struct GitHubCacheHit {
    pub body: Value,
    pub etag: Option<String>,
    pub age_seconds: u64,
    pub state: GitHubCacheState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredCacheEntry {
    stored_at_epoch_seconds: u64,
    etag: Option<String>,
    body: Value,
}

#[derive(Debug, Clone)]
struct MemoryCacheEntry {
    stored_at: SystemTime,
    etag: Option<String>,
    body: Value,
    last_used: SystemTime,
}

pub(crate) struct GitHubCache {
    root: PathBuf,
    memory: Mutex<HashMap<String, MemoryCacheEntry>>,
}

impl GitHubCache {
    pub(crate) fn new() -> Self {
        Self {
            root: state::daemon_root().join("github-cache").join("v1"),
            memory: Mutex::new(HashMap::new()),
        }
    }

    #[cfg(test)]
    pub(crate) fn test_with_root(root: PathBuf) -> Self {
        Self {
            root: root.join("github-cache").join("v1"),
            memory: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn key(parts: &[&str]) -> String {
        let mut hasher = Sha256::new();
        for part in parts {
            hasher.update(part.as_bytes());
            hasher.update([0]);
        }
        hex::encode(hasher.finalize())
    }

    pub(crate) fn get(&self, key: &str, policy: GitHubCachePolicy) -> Option<GitHubCacheHit> {
        if !policy.is_enabled() {
            return None;
        }
        if let Some(hit) = self.get_memory(key, policy) {
            return Some(hit);
        }
        if !policy.disk {
            return None;
        }
        let hit = self.get_disk(key, policy)?;
        self.store_memory(
            key,
            MemoryCacheEntry {
                stored_at: SystemTime::now() - Duration::from_secs(hit.age_seconds),
                etag: hit.etag.clone(),
                body: hit.body.clone(),
                last_used: SystemTime::now(),
            },
        );
        Some(hit)
    }

    pub(crate) fn stale(&self, key: &str, policy: GitHubCachePolicy) -> Option<GitHubCacheHit> {
        let mut stale_policy = policy;
        stale_policy.fresh_for = Duration::ZERO;
        self.get(key, stale_policy)
            .filter(|hit| hit.state == GitHubCacheState::Stale)
    }

    pub(crate) fn store(
        &self,
        key: &str,
        body: &Value,
        etag: Option<String>,
        policy: GitHubCachePolicy,
    ) {
        if !policy.is_enabled() {
            return;
        }
        let entry = MemoryCacheEntry {
            stored_at: SystemTime::now(),
            etag: etag.clone(),
            body: body.clone(),
            last_used: SystemTime::now(),
        };
        self.store_memory(key, entry);
        if policy.disk {
            self.store_disk(key, body, etag);
        }
    }

    fn get_memory(&self, key: &str, policy: GitHubCachePolicy) -> Option<GitHubCacheHit> {
        let mut guard = self.memory.lock().ok()?;
        let entry = guard.get_mut(key)?;
        let age = entry.stored_at.elapsed().ok()?;
        let state = classify_age(age, policy)?;
        entry.last_used = SystemTime::now();
        Some(GitHubCacheHit {
            body: entry.body.clone(),
            etag: entry.etag.clone(),
            age_seconds: age.as_secs(),
            state,
        })
    }

    fn get_disk(&self, key: &str, policy: GitHubCachePolicy) -> Option<GitHubCacheHit> {
        let path = self.path_for_key(key);
        let raw = fs::read_to_string(path).ok()?;
        let entry: StoredCacheEntry = serde_json::from_str(&raw).ok()?;
        let stored_at = UNIX_EPOCH + Duration::from_secs(entry.stored_at_epoch_seconds);
        let age = stored_at.elapsed().ok()?;
        let state = classify_age(age, policy)?;
        Some(GitHubCacheHit {
            body: entry.body,
            etag: entry.etag,
            age_seconds: age.as_secs(),
            state,
        })
    }

    fn store_memory(&self, key: &str, entry: MemoryCacheEntry) {
        if let Ok(mut guard) = self.memory.lock() {
            guard.insert(key.to_string(), entry);
            trim_memory(&mut guard);
        }
    }

    fn store_disk(&self, key: &str, body: &Value, etag: Option<String>) {
        if fs::create_dir_all(self.path_dir_for_key(key)).is_err() {
            return;
        }
        let entry = StoredCacheEntry {
            stored_at_epoch_seconds: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |duration| duration.as_secs()),
            etag,
            body: body.clone(),
        };
        let path = self.path_for_key(key);
        let tmp_path = path.with_extension("json.tmp");
        if let Ok(raw) = serde_json::to_vec(&entry)
            && fs::write(&tmp_path, raw).is_ok()
        {
            let _ = fs::rename(&tmp_path, &path);
        }
        self.maybe_gc_disk();
    }

    fn maybe_gc_disk(&self) {
        let Ok(entries) = fs::read_dir(&self.root) else {
            return;
        };
        let mut files = Vec::new();
        for dir_entry in entries.flatten() {
            let Ok(children) = fs::read_dir(dir_entry.path()) else {
                continue;
            };
            for child in children.flatten() {
                if let Ok(metadata) = child.metadata() {
                    files.push((metadata.modified().unwrap_or(UNIX_EPOCH), child.path()));
                }
            }
        }
        if files.len() <= DISK_GC_ENTRY_CAP {
            return;
        }
        files.sort_by_key(|(modified, _)| *modified);
        for (_, path) in files.into_iter().take(DISK_GC_ENTRY_CAP / 4) {
            let _ = fs::remove_file(path);
        }
    }

    fn path_dir_for_key(&self, key: &str) -> PathBuf {
        self.root.join(&key[..2])
    }

    fn path_for_key(&self, key: &str) -> PathBuf {
        self.path_dir_for_key(key).join(format!("{key}.json"))
    }
}

fn classify_age(age: Duration, policy: GitHubCachePolicy) -> Option<GitHubCacheState> {
    if age <= policy.fresh_for {
        return Some(GitHubCacheState::Fresh);
    }
    if age <= policy.stale_for {
        return Some(GitHubCacheState::Stale);
    }
    None
}

fn trim_memory(cache: &mut HashMap<String, MemoryCacheEntry>) {
    if cache.len() <= MEMORY_ENTRY_CAP {
        return;
    }
    let mut entries = cache
        .iter()
        .map(|(key, entry)| (key.clone(), entry.last_used))
        .collect::<Vec<_>>();
    entries.sort_by_key(|(_, last_used)| *last_used);
    for (key, _) in entries.into_iter().take(MEMORY_ENTRY_CAP / 4) {
        cache.remove(&key);
    }
}
