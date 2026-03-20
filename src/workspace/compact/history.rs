use std::path::Path;
use std::result;

use fs_err as fs;
use tracing::warn;

use super::HISTORY_LIMIT;

pub(super) fn trim_history(history_dir: &Path) {
    if !history_dir.exists() {
        return;
    }

    let Ok(entries) = fs::read_dir(&history_dir) else {
        return;
    };
    let mut files: Vec<_> = entries
        .filter_map(result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();
    files.sort();

    let excess = files.len().saturating_sub(HISTORY_LIMIT);
    for path in files.into_iter().take(excess) {
        if let Err(error) = fs::remove_file(&path) {
            warn!(path = %path.display(), %error, "failed to remove history file");
        }
    }
}
