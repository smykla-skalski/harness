use std::io;
use std::path::Path;

use fs_err as fs;
use serde::Deserialize;
use walkdir::WalkDir;

use crate::errors::CliError;
use crate::infra::io::read_json_typed;

/// Read the plugin version from `.claude-plugin/plugin.json`.
///
/// Returns `Ok(None)` if the file is missing.
///
/// # Errors
/// Returns `CliError` if the manifest exists but is invalid.
pub(super) fn read_plugin_version(plugin_dir: &Path) -> Result<Option<String>, CliError> {
    #[derive(Deserialize)]
    struct PluginManifest {
        version: String,
    }

    let json_path = plugin_dir.join(".claude-plugin").join("plugin.json");
    if !json_path.exists() {
        return Ok(None);
    }
    let manifest: PluginManifest = read_json_typed(&json_path)?;
    Ok(Some(manifest.version))
}

/// Sync plugin source directories to the Claude Code plugin cache.
///
/// Copies `agents/`, `hooks/`, and `skills/` from the project source
/// into `~/.claude/plugins/cache/harness/suite/{version}/`, creating
/// or overwriting files as needed. Skips the binary (`harness`) since
/// it is already current.
///
/// # Errors
/// Returns `CliError` if the manifest is invalid or the cache sync fails.
pub(super) fn sync_plugin_cache(plugin_dir: &Path, home: &Path) -> Result<(), CliError> {
    let Some(version) = read_plugin_version(plugin_dir)? else {
        return Ok(());
    };

    let cache_dir = home
        .join(".claude")
        .join("plugins")
        .join("cache")
        .join("harness")
        .join("suite")
        .join(&version);

    if !cache_dir.is_dir() {
        return Ok(());
    }

    for subdir in &["agents", "hooks", "skills"] {
        let source = plugin_dir.join(subdir);
        if source.is_dir() {
            let target = cache_dir.join(subdir);
            sync_directory(&source, &target).map_err(CliError::from)?;
        }
    }

    Ok(())
}

/// Recursively copy all files from `source` into `target`, overwriting
/// any file whose content differs. Creates subdirectories as needed.
pub(super) fn sync_directory(source: &Path, target: &Path) -> io::Result<()> {
    fs::create_dir_all(target)?;
    for entry in WalkDir::new(source).min_depth(1).sort_by_file_name() {
        let entry = entry.map_err(io::Error::other)?;
        let rel = entry
            .path()
            .strip_prefix(source)
            .map_err(io::Error::other)?;
        let dest = target.join(rel);

        if entry.file_type().is_dir() {
            fs::create_dir_all(&dest)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            let source_content = fs::read(entry.path())?;
            let needs_write = if let Ok(existing) = fs::read(&dest) {
                existing != source_content
            } else {
                true
            };
            if needs_write {
                fs::copy(entry.path(), &dest)?;
            }
        }
    }
    Ok(())
}
