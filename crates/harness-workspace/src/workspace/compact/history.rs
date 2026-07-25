use std::path::Path;
use std::path::PathBuf;
use std::result;

use fs_err as fs;

use super::HISTORY_LIMIT;

pub(super) fn trim_history(history_dir: &Path) {
    if !history_dir.exists() {
        return;
    }

    let Ok(entries) = fs::read_dir(history_dir) else {
        return;
    };
    let mut files = history_files(entries);
    files.sort();
    remove_excess_history_files(files);
}

fn history_files(entries: fs::ReadDir) -> Vec<PathBuf> {
    entries
        .filter_map(result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect()
}

fn remove_excess_history_files(files: Vec<PathBuf>) {
    let excess = files.len().saturating_sub(HISTORY_LIMIT);
    for path in files.into_iter().take(excess) {
        let _ = fs::remove_file(&path);
    }
}
