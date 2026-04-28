use std::fmt::Write as _;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use chrono::Utc;
use fs_err as fs;

use crate::errors::CliError;
use crate::infra::io::write_text;

const COUNCIL_PLUGIN_HEADER: &str = r#"[plugins."council@council"]"#;
const LEGACY_COUNCIL_PLUGIN_HEADER: &str = r#"[plugins."council@council-home"]"#;
const COUNCIL_MARKETPLACE_HEADER: &str = "[marketplaces.council]";
const LEGACY_COUNCIL_MARKETPLACE_HEADER: &str = "[marketplaces.council-home]";

pub(super) fn sync_codex_council_marketplace(
    project_dir: &Path,
    home: &Path,
) -> Result<(), CliError> {
    let link_path = codex_marketplace_link(home);
    sync_repo_symlink(project_dir, &link_path)?;
    sync_codex_config(
        &home.join(".codex").join("config.toml"),
        &link_path,
        &Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    )
}

fn codex_marketplace_link(home: &Path) -> PathBuf {
    home.join("codex-marketplaces").join("council")
}

fn sync_repo_symlink(target: &Path, link_path: &Path) -> Result<(), CliError> {
    if let Ok(metadata) = fs::symlink_metadata(link_path) {
        let same_target = metadata.file_type().is_symlink()
            && fs::read_link(link_path).is_ok_and(|existing| existing == target);
        if same_target {
            return Ok(());
        }
        if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
            fs::remove_dir_all(link_path).map_err(CliError::from)?;
        } else {
            fs::remove_file(link_path).map_err(CliError::from)?;
        }
    }

    if let Some(parent) = link_path.parent() {
        fs::create_dir_all(parent).map_err(CliError::from)?;
    }
    symlink(target, link_path).map_err(CliError::from)?;
    Ok(())
}

fn sync_codex_config(
    config_path: &Path,
    marketplace_path: &Path,
    now: &str,
) -> Result<(), CliError> {
    let existing = fs::read_to_string(config_path).unwrap_or_default();
    let (mut base, removed) = strip_sections(
        &existing,
        &[
            COUNCIL_PLUGIN_HEADER,
            LEGACY_COUNCIL_PLUGIN_HEADER,
            COUNCIL_MARKETPLACE_HEADER,
            LEGACY_COUNCIL_MARKETPLACE_HEADER,
        ],
    );

    trim_trailing_blank_lines(&mut base);
    if !base.is_empty() {
        base.push('\n');
    }

    let council_enabled = removed
        .iter()
        .find_map(|(header, body)| {
            (*header == COUNCIL_PLUGIN_HEADER || *header == LEGACY_COUNCIL_PLUGIN_HEADER)
                .then(|| section_enabled(body))
                .flatten()
        })
        .unwrap_or(true);

    write!(
        base,
        "{COUNCIL_PLUGIN_HEADER}\nenabled = {council_enabled}\n\n{COUNCIL_MARKETPLACE_HEADER}\nlast_updated = \"{now}\"\nsource_type = \"local\"\nsource = \"{}\"\n",
        marketplace_path.display()
    )
    .expect("writing to a string cannot fail");

    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent).map_err(CliError::from)?;
    }
    write_text(config_path, &base)
}

fn section_enabled(body: &str) -> Option<bool> {
    body.lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix("enabled = "))
        .and_then(|value| match value {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        })
}

fn strip_sections<'a>(content: &'a str, headers: &[&'a str]) -> (String, Vec<(&'a str, String)>) {
    let mut kept = String::new();
    let mut removed = Vec::new();
    let mut current_header: Option<&str> = None;
    let mut current_body = String::new();
    let mut keep_current = true;

    for line in content.split_inclusive('\n') {
        if let Some(header) = section_header(line) {
            flush_section(
                &mut kept,
                &mut removed,
                current_header,
                &mut current_body,
                keep_current,
            );
            current_header = Some(header);
            keep_current = !headers.contains(&header);
        }

        if current_header.is_some() {
            current_body.push_str(line);
        } else {
            kept.push_str(line);
        }
    }

    flush_section(
        &mut kept,
        &mut removed,
        current_header,
        &mut current_body,
        keep_current,
    );

    (kept, removed)
}

fn flush_section<'a>(
    kept: &mut String,
    removed: &mut Vec<(&'a str, String)>,
    current_header: Option<&'a str>,
    current_body: &mut String,
    keep_current: bool,
) {
    let Some(header) = current_header else {
        current_body.clear();
        return;
    };

    if keep_current {
        kept.push_str(current_body);
    } else {
        removed.push((header, current_body.clone()));
    }
    current_body.clear();
}

fn section_header(line: &str) -> Option<&str> {
    let trimmed = line.trim_end_matches(['\n', '\r']);
    (trimmed.starts_with('[') && trimmed.ends_with(']')).then_some(trimmed)
}

fn trim_trailing_blank_lines(text: &mut String) {
    while text.ends_with("\n\n") {
        text.pop();
    }
}

#[cfg(test)]
mod tests {
    use fs_err as fs;

    use super::{codex_marketplace_link, sync_codex_config, sync_codex_council_marketplace};

    #[test]
    fn sync_codex_council_marketplace_migrates_legacy_config_and_symlinks_repo() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let home = tmp.path().join("home");
        let project = tmp.path().join("project");
        fs::create_dir_all(&home).expect("home");
        fs::create_dir_all(&project).expect("project");
        fs::create_dir_all(home.join(".codex")).expect("codex dir");
        fs::write(
            home.join(".codex").join("config.toml"),
            r#"[plugins."council@council-home"]
enabled = true

[marketplaces.council-home]
last_updated = "2026-04-20T03:00:00Z"
source_type = "local"
source = "/Users/example/codex-marketplaces/council"
"#,
        )
        .expect("write config");

        sync_codex_council_marketplace(&project, &home).expect("sync succeeds");

        let link = codex_marketplace_link(&home);
        assert!(
            fs::symlink_metadata(&link)
                .expect("metadata")
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read_link(&link).expect("read link"), project);

        let config = fs::read_to_string(home.join(".codex").join("config.toml")).expect("config");
        assert!(config.contains("[plugins.\"council@council\"]"));
        assert!(config.contains("enabled = true"));
        assert!(config.contains("[marketplaces.council]"));
        assert!(config.contains(&format!("source = \"{}\"", link.display())));
        assert!(!config.contains("council@council-home"));
        assert!(!config.contains("[marketplaces.council-home]"));
    }

    #[test]
    fn sync_codex_config_creates_enabled_council_when_missing() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let config = tmp.path().join(".codex").join("config.toml");
        let marketplace = tmp.path().join("codex-marketplaces").join("council");

        sync_codex_config(&config, &marketplace, "2026-04-28T00:00:00Z").expect("sync config");

        let written = fs::read_to_string(config).expect("read config");
        assert!(written.contains("[plugins.\"council@council\"]"));
        assert!(written.contains("enabled = true"));
        assert!(written.contains("[marketplaces.council]"));
        assert!(written.contains("source_type = \"local\""));
    }
}
