use std::io;
use std::path::Path;

use chrono::Utc;
use fs_err as fs;
use serde::Deserialize;
use serde_json::Value;
use walkdir::WalkDir;

use crate::errors::CliError;
use crate::infra::io::read_json_typed;

#[derive(Deserialize)]
struct PluginManifest {
    name: String,
    version: String,
}

fn read_plugin_manifest(plugin_dir: &Path) -> Result<Option<PluginManifest>, CliError> {
    let json_path = plugin_dir.join(".claude-plugin").join("plugin.json");
    if !json_path.exists() {
        return Ok(None);
    }
    let manifest: PluginManifest = read_json_typed(&json_path)?;
    Ok(Some(manifest))
}

/// Read the plugin version from `.claude-plugin/plugin.json`.
///
/// Returns `Ok(None)` if the file is missing.
///
/// # Errors
/// Returns `CliError` if the manifest exists but is invalid.
#[cfg(test)]
pub(super) fn read_plugin_version(plugin_dir: &Path) -> Result<Option<String>, CliError> {
    Ok(read_plugin_manifest(plugin_dir)?.map(|m| m.version))
}

/// Sync a plugin source directory to the Claude Code plugin cache.
///
/// Reads the plugin name and version from `.claude-plugin/plugin.json`, creates
/// `~/.claude/plugins/cache/harness/{name}/{version}/` if absent, copies
/// `agents/`, `hooks/`, `skills/`, and `.claude-plugin/` from the project source
/// into that cache directory, and registers the plugin in
/// `~/.claude/plugins/installed_plugins.json` (upsert, skipped if file absent).
///
/// # Errors
/// Returns `CliError` if the manifest is invalid or the cache sync fails.
pub(super) fn sync_plugin_cache(plugin_dir: &Path, home: &Path) -> Result<(), CliError> {
    let Some(manifest) = read_plugin_manifest(plugin_dir)? else {
        return Ok(());
    };

    let cache_dir = home
        .join(".claude")
        .join("plugins")
        .join("cache")
        .join("harness")
        .join(&manifest.name)
        .join(&manifest.version);

    fs::create_dir_all(&cache_dir).map_err(CliError::from)?;

    for subdir in &[".claude-plugin", "agents", "hooks", "skills"] {
        let source = plugin_dir.join(subdir);
        if source.is_dir() {
            let target = cache_dir.join(subdir);
            sync_directory(&source, &target).map_err(CliError::from)?;
        }
    }

    let launcher = plugin_dir.join("harness");
    if launcher.is_file() {
        sync_file(&launcher, &cache_dir.join("harness")).map_err(CliError::from)?;
    }

    register_in_installed_plugins(&manifest.name, &manifest.version, &cache_dir, home)?;

    Ok(())
}

/// Upsert `{name}@harness` in `~/.claude/plugins/installed_plugins.json`.
///
/// Silently returns `Ok` when the file is absent — first-install registration
/// is expected to happen through Claude Code's plugin installer, not here.
fn register_in_installed_plugins(
    name: &str,
    version: &str,
    install_path: &Path,
    home: &Path,
) -> Result<(), CliError> {
    let installed_path = home
        .join(".claude")
        .join("plugins")
        .join("installed_plugins.json");

    if !installed_path.exists() {
        return Ok(());
    }

    let content = fs::read_to_string(&installed_path).map_err(CliError::from)?;
    let mut root: Value =
        serde_json::from_str(&content).map_err(|e| CliError::from(io::Error::other(e)))?;

    let install_path_str = install_path.to_string_lossy().to_string();
    let now = Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let key = format!("{name}@harness");

    let plugins = root
        .get_mut("plugins")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            CliError::from(io::Error::other(
                "installed_plugins.json missing plugins object",
            ))
        })?;

    if let Some(arr) = plugins.get_mut(&key).and_then(Value::as_array_mut) {
        if let Some(item) = arr
            .iter_mut()
            .find(|e| e.get("scope").and_then(Value::as_str) == Some("user"))
        {
            let installed_at = item
                .get("installedAt")
                .cloned()
                .unwrap_or_else(|| serde_json::json!(now));
            *item = serde_json::json!({
                "scope": "user",
                "installPath": install_path_str,
                "version": version,
                "installedAt": installed_at,
                "lastUpdated": now
            });
        } else {
            arr.push(serde_json::json!({
                "scope": "user",
                "installPath": install_path_str,
                "version": version,
                "installedAt": now,
                "lastUpdated": now
            }));
        }
    } else {
        plugins.insert(
            key,
            serde_json::json!([{
                "scope": "user",
                "installPath": install_path_str,
                "version": version,
                "installedAt": now,
                "lastUpdated": now
            }]),
        );
    }

    write_installed_plugins(&installed_path, &root)
}

fn write_installed_plugins(path: &Path, value: &Value) -> Result<(), CliError> {
    let content =
        serde_json::to_string_pretty(value).map_err(|e| CliError::from(io::Error::other(e)))?;
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, content).map_err(CliError::from)?;
    fs::rename(&tmp, path).map_err(CliError::from)?;
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

fn sync_file(source: &Path, target: &Path) -> io::Result<()> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }

    let source_content = fs::read(source)?;
    let needs_write = if let Ok(existing) = fs::read(target) {
        existing != source_content
    } else {
        true
    };
    if needs_write {
        fs::copy(source, target)?;
    }
    Ok(())
}
