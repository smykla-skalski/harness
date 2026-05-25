use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::SystemTime;

use fs_err as fs;

use crate::errors::{CliError, io_for};
use crate::task_board::types::TaskBoardItem;

use super::read_path;

/// One memoized parse, tagged with the source file's modification time and
/// length. A rewrite always bumps at least the mtime, so a stale entry is
/// detected on the next read without any explicit invalidation.
struct CachedEntry {
    mtime: SystemTime,
    len: u64,
    item: TaskBoardItem,
}

/// The outcome of consulting the cache for one file: a ready item, or a miss
/// carrying the freshly stat-ed `(mtime, len)` so the caller can parse without
/// stat-ing the file a second time.
pub(super) enum Resolve {
    Hit(TaskBoardItem),
    Miss { mtime: SystemTime, len: u64 },
}

/// Process-wide memoization for task-board markdown parsing.
///
/// The daemon orchestrator lists the board on a short interval, and every list
/// used to reparse all items from scratch - `yaml_rust2` frontmatter scanning
/// dominated the daemon's idle CPU. Keying parsed items by `(mtime, len)` lets
/// an unchanged file skip the parse entirely. The expensive parse runs outside
/// the lock so concurrent rayon workers stay parallel.
pub(super) struct ParseCache {
    entries: Mutex<HashMap<PathBuf, CachedEntry>>,
    parses: AtomicU64,
}

impl ParseCache {
    pub(super) fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            parses: AtomicU64::new(0),
        }
    }

    /// Look the file up by its current `(mtime, len)`, returning the cached
    /// parse on a hit or the stat metadata to parse with on a miss.
    ///
    /// # Errors
    /// Returns `CliError` when the file cannot be stat-ed.
    pub(super) fn resolve(&self, path: &Path) -> Result<Resolve, CliError> {
        let metadata =
            fs::metadata(path).map_err(|error| io_for("stat board item", path, &error))?;
        let len = metadata.len();
        let mtime = metadata
            .modified()
            .map_err(|error| io_for("read board item mtime", path, &error))?;
        Ok(match self.lookup(path, mtime, len) {
            Some(item) => Resolve::Hit(item),
            None => Resolve::Miss { mtime, len },
        })
    }

    /// Parse a file that missed the cache and memoize it under `(mtime, len)`.
    ///
    /// # Errors
    /// Returns `CliError` when the file cannot be read or parsed.
    pub(super) fn parse_miss(
        &self,
        path: &Path,
        mtime: SystemTime,
        len: u64,
    ) -> Result<TaskBoardItem, CliError> {
        let item = read_path(path)?;
        self.parses.fetch_add(1, Ordering::Relaxed);
        self.insert(path, mtime, len, item.clone());
        Ok(item)
    }

    pub(super) fn forget(&self, path: &Path) {
        self.entries
            .lock()
            .expect("task-board parse cache lock")
            .remove(path);
    }

    fn lookup(&self, path: &Path, mtime: SystemTime, len: u64) -> Option<TaskBoardItem> {
        let entries = self.entries.lock().expect("task-board parse cache lock");
        entries
            .get(path)
            .filter(|entry| entry.mtime == mtime && entry.len == len)
            .map(|entry| entry.item.clone())
    }

    fn insert(&self, path: &Path, mtime: SystemTime, len: u64, item: TaskBoardItem) {
        self.entries
            .lock()
            .expect("task-board parse cache lock")
            .insert(path.to_path_buf(), CachedEntry { mtime, len, item });
    }

    /// Return the parsed item for `path`, reusing the cached parse when the
    /// file is unchanged. Test-only convenience over [`resolve`]/[`parse_miss`].
    ///
    /// # Errors
    /// Returns `CliError` when the file cannot be stat-ed, read, or parsed.
    #[cfg(test)]
    pub(super) fn read(&self, path: &Path) -> Result<TaskBoardItem, CliError> {
        match self.resolve(path)? {
            Resolve::Hit(item) => Ok(item),
            Resolve::Miss { mtime, len } => self.parse_miss(path, mtime, len),
        }
    }

    #[cfg(test)]
    pub(super) fn parse_count(&self) -> u64 {
        self.parses.load(Ordering::Relaxed)
    }
}

pub(super) static BOARD_PARSE_CACHE: LazyLock<ParseCache> = LazyLock::new(ParseCache::new);
