use std::collections::BTreeMap;
use std::fs::{DirEntry, read_dir};
use std::path::{Path, PathBuf};

use tracing::debug;

use crate::errors::{CliError, CliErrorKind};

use super::files::io_err;
use super::model::PlannedOutput;

/// Walk `local-skills/claude/` and plan a relative symlink at
/// `.claude/skills/<name>` → `../../local-skills/claude/<name>/` for each
/// immediate subdirectory found.  Hidden entries (names starting with `.`) are
/// skipped.  If the source directory does not exist the function returns
/// without error.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub(super) fn render_local_skills(
    repo_root: &Path,
    outputs: &mut BTreeMap<PathBuf, PlannedOutput>,
) -> Result<(), CliError> {
    let source_root = repo_root.join("local-skills").join("claude");
    if !source_root.exists() {
        debug!(
            path = %source_root.display(),
            "local-skills/claude/ not found, skipping local skill symlinks"
        );
        return Ok(());
    }
    let claude_skills_root = repo_root.join(".claude").join("skills");
    let symlinks = collect_skill_symlinks(&source_root, &claude_skills_root)?;
    if symlinks.is_empty() {
        return Ok(());
    }
    let entry = outputs
        .entry(claude_skills_root.clone())
        .or_insert_with(|| PlannedOutput {
            managed_root: claude_skills_root,
            files: BTreeMap::new(),
            symlinks: BTreeMap::new(),
        });
    entry.symlinks.extend(symlinks);
    Ok(())
}

/// Collect `(link, target)` pairs from `source_root`, one per visible subdir.
fn collect_skill_symlinks(
    source_root: &Path,
    claude_skills_root: &Path,
) -> Result<BTreeMap<PathBuf, PathBuf>, CliError> {
    let mut symlinks = BTreeMap::new();
    for dir_entry in read_dir(source_root).map_err(|e| io_err(&e))? {
        let dir_entry = dir_entry.map_err(|e| io_err(&e))?;
        if let Some((link, target)) = skill_symlink(claude_skills_root, &dir_entry)? {
            symlinks.insert(link, target);
        }
    }
    Ok(symlinks)
}

/// Return `(link, target)` for a local-skill directory entry, or `None` when
/// the entry should be skipped (hidden name or not a directory).
fn skill_symlink(
    claude_skills_root: &Path,
    dir_entry: &DirEntry,
) -> Result<Option<(PathBuf, PathBuf)>, CliError> {
    let name = dir_entry.file_name();
    let name_str = name.to_str().ok_or_else(|| {
        CliErrorKind::usage_error(format!(
            "local-skills/claude entry has non-UTF-8 name: {}",
            dir_entry.path().display()
        ))
    })?;
    if name_str.starts_with('.') || !dir_entry.file_type().map_err(|e| io_err(&e))?.is_dir() {
        return Ok(None);
    }
    let link = claude_skills_root.join(name_str);
    // Relative target: from .claude/skills/<name>, two levels up to repo root,
    // then into local-skills/claude/<name>.
    let target = PathBuf::from("../../local-skills/claude").join(name_str);
    Ok(Some((link, target)))
}

#[cfg(test)]
mod tests {
    use std::fs::create_dir_all;

    use tempfile::TempDir;

    use super::*;

    fn make_skill_dir(tmp: &TempDir, name: &str) {
        create_dir_all(tmp.path().join("local-skills").join("claude").join(name)).unwrap();
    }

    #[test]
    fn plans_symlinks_for_each_subdir() {
        let tmp = TempDir::new().unwrap();
        make_skill_dir(&tmp, "alpha");
        make_skill_dir(&tmp, "beta");

        let mut outputs = BTreeMap::new();
        render_local_skills(tmp.path(), &mut outputs).unwrap();

        let claude_skills = tmp.path().join(".claude").join("skills");
        let output = outputs
            .get(&claude_skills)
            .expect("output for .claude/skills");

        let alpha_link = claude_skills.join("alpha");
        let beta_link = claude_skills.join("beta");
        assert_eq!(
            output.symlinks.get(&alpha_link),
            Some(&PathBuf::from("../../local-skills/claude/alpha")),
            "alpha symlink target"
        );
        assert_eq!(
            output.symlinks.get(&beta_link),
            Some(&PathBuf::from("../../local-skills/claude/beta")),
            "beta symlink target"
        );
    }

    #[test]
    fn skips_hidden_entries() {
        let tmp = TempDir::new().unwrap();
        make_skill_dir(&tmp, "visible");
        make_skill_dir(&tmp, ".hidden");

        let mut outputs = BTreeMap::new();
        render_local_skills(tmp.path(), &mut outputs).unwrap();

        let claude_skills = tmp.path().join(".claude").join("skills");
        let output = outputs.get(&claude_skills).expect("output entry");
        assert!(
            output.symlinks.contains_key(&claude_skills.join("visible")),
            "visible dir present"
        );
        assert!(
            !output.symlinks.contains_key(&claude_skills.join(".hidden")),
            "hidden dir excluded"
        );
    }

    #[test]
    fn no_error_when_source_root_absent() {
        let tmp = TempDir::new().unwrap();
        let mut outputs = BTreeMap::new();
        render_local_skills(tmp.path(), &mut outputs).unwrap();
        assert!(outputs.is_empty(), "no outputs when source absent");
    }

    #[test]
    fn merges_with_existing_output_entry() {
        let tmp = TempDir::new().unwrap();
        make_skill_dir(&tmp, "gamma");

        let claude_skills = tmp.path().join(".claude").join("skills");
        let existing_file = claude_skills.join("some-skill/SKILL.md");
        let mut outputs = BTreeMap::new();
        outputs.insert(
            claude_skills.clone(),
            PlannedOutput {
                managed_root: claude_skills.clone(),
                files: BTreeMap::from([(existing_file.clone(), "body".to_owned())]),
                symlinks: BTreeMap::new(),
            },
        );

        render_local_skills(tmp.path(), &mut outputs).unwrap();

        let output = outputs.get(&claude_skills).unwrap();
        assert!(
            output.files.contains_key(&existing_file),
            "existing file preserved"
        );
        assert!(
            output.symlinks.contains_key(&claude_skills.join("gamma")),
            "gamma symlink added"
        );
    }

    #[test]
    fn skips_plain_files_in_source_root() {
        let tmp = TempDir::new().unwrap();
        // Create the source dir but put a file inside instead of a subdir
        let source = tmp.path().join("local-skills").join("claude");
        create_dir_all(&source).unwrap();
        std::fs::write(source.join("README.md"), "readme").unwrap();
        make_skill_dir(&tmp, "real-skill");

        let mut outputs = BTreeMap::new();
        render_local_skills(tmp.path(), &mut outputs).unwrap();

        let claude_skills = tmp.path().join(".claude").join("skills");
        let output = outputs.get(&claude_skills).unwrap();
        // Only one symlink for real-skill, not for README.md
        assert_eq!(output.symlinks.len(), 1);
        assert!(
            output
                .symlinks
                .contains_key(&claude_skills.join("real-skill"))
        );
    }
}
