use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use walkdir::WalkDir;

use crate::errors::CliError;
use crate::infra::io::read_text;

use super::files::io_err;
use super::model::{PluginDefinition, RenderTarget};
use super::rewrite::rewrite_text_for_target;

pub(super) fn copy_plugin_assets(
    plugin: &PluginDefinition,
    dest_root: &Path,
    files: &mut BTreeMap<PathBuf, String>,
    target: RenderTarget,
) -> Result<(), CliError> {
    copy_extra_text_files(
        &plugin.root,
        dest_root,
        files,
        &["plugin.yaml", "hooks.yaml", "skills"],
        target,
        &plugin.source.name,
    )
}

pub(super) fn copy_extra_text_files(
    source_root: &Path,
    dest_root: &Path,
    files: &mut BTreeMap<PathBuf, String>,
    excludes: &[&str],
    target: RenderTarget,
    source_name: &str,
) -> Result<(), CliError> {
    let exclude_set: BTreeSet<&str> = excludes.iter().copied().collect();
    for entry in WalkDir::new(source_root).min_depth(1) {
        let entry = entry.map_err(|error| io_err(&error))?;
        let path = entry.path();
        let relative = path
            .strip_prefix(source_root)
            .expect("walkdir entry stays under source root");
        let first = relative
            .components()
            .next()
            .and_then(|component| component.as_os_str().to_str())
            .unwrap_or("");
        if exclude_set.contains(first) || entry.file_type().is_dir() {
            continue;
        }
        let content = read_text(path)?;
        let content = if path.extension() == Some(OsStr::new("md")) {
            rewrite_text_for_target(&content, target, source_name)
        } else {
            content
        };
        files.insert(dest_root.join(relative), content);
    }
    Ok(())
}
