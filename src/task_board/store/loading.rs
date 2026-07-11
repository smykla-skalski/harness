use std::path::PathBuf;

use fs_err as fs;
use rayon::prelude::*;

use crate::errors::{CliError, io_for};

use super::parse_cache::{BOARD_PARSE_CACHE, Resolve};
use super::{
    TaskBoardItem, TaskBoardStore, apply_canonical_persisted_status, read_path, validate_loaded_id,
};

type ItemAtPath = (PathBuf, TaskBoardItem);

impl TaskBoardStore {
    /// Load one board item by ID.
    ///
    /// # Errors
    /// Returns `CliError` if the ID is unsafe, the file is missing, or the
    /// markdown/frontmatter payload cannot be parsed or repaired on disk.
    pub fn get(&self, id: &str) -> Result<TaskBoardItem, CliError> {
        let path = self.path_for(id)?;
        let item = read_path(&path)?;
        self.finish_get(id, item)
    }

    pub(super) fn finish_get(
        &self,
        id: &str,
        mut item: TaskBoardItem,
    ) -> Result<TaskBoardItem, CliError> {
        validate_loaded_id(id, &item)?;
        if !apply_canonical_persisted_status(&mut item) {
            return Ok(item);
        }
        self.with_mutation_lock(|| self.get_locked(id))
    }

    pub(super) fn get_locked(&self, id: &str) -> Result<TaskBoardItem, CliError> {
        let path = self.path_for(id)?;
        let mut item = read_path(&path)?;
        validate_loaded_id(id, &item)?;
        Self::repair_legacy_status_at_locked(&path, &mut item)?;
        Ok(item)
    }

    /// Read and parse every markdown item in the tasks directory.
    ///
    /// The directory scan is cheap, but parsing the YAML frontmatter is not, so
    /// cold parses fan out across rayon and steady-state cache hits cost one
    /// `stat` per file.
    ///
    /// # Errors
    /// Returns `CliError` if the directory or an item cannot be read, parsed,
    /// or repaired on disk.
    pub(super) fn read_all_items(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        let items = self.read_all_items_unrepaired()?;
        self.finish_read_all_items(items)
    }

    pub(super) fn finish_read_all_items(
        &self,
        items: Vec<ItemAtPath>,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        if !items.iter().any(|(_, item)| needs_status_repair(item)) {
            return Ok(without_paths(items));
        }
        self.with_mutation_lock(|| self.read_all_items_locked())
    }

    fn read_all_items_locked(&self) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut items = self.read_all_items_unrepaired()?;
        for (path, item) in &mut items {
            Self::repair_legacy_status_at_locked(path, item)?;
        }
        Ok(without_paths(items))
    }

    fn read_all_items_unrepaired(&self) -> Result<Vec<ItemAtPath>, CliError> {
        let paths = self.task_paths()?;
        let mut items = Vec::with_capacity(paths.len());
        let mut misses = Vec::new();
        for path in paths {
            match BOARD_PARSE_CACHE.resolve(&path)? {
                Resolve::Hit(arc) => items.push((path, (*arc).clone())),
                Resolve::Miss { mtime, len } => misses.push((path, mtime, len)),
            }
        }
        if !misses.is_empty() {
            let parsed = misses
                .par_iter()
                .map(|(path, mtime, len)| {
                    BOARD_PARSE_CACHE
                        .parse_miss(path, *mtime, *len)
                        .map(|arc| (path.clone(), (*arc).clone()))
                })
                .collect::<Result<Vec<_>, _>>()?;
            items.extend(parsed);
        }
        Ok(items)
    }

    fn task_paths(&self) -> Result<Vec<PathBuf>, CliError> {
        let dir = self.tasks_dir();
        if !dir.exists() {
            return Ok(Vec::new());
        }
        let mut paths = Vec::new();
        for entry in fs::read_dir(&dir).map_err(|error| io_for("read dir", &dir, &error))? {
            let path = entry
                .map_err(|error| io_for("read dir entry", &dir, &error))?
                .path();
            if path.extension().and_then(|ext| ext.to_str()) == Some("md") {
                paths.push(path);
            }
        }
        Ok(paths)
    }
}

fn needs_status_repair(item: &TaskBoardItem) -> bool {
    item.status != item.status.canonical_persisted_status()
}

fn without_paths(items: Vec<ItemAtPath>) -> Vec<TaskBoardItem> {
    items.into_iter().map(|(_, item)| item).collect()
}
