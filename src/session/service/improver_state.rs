//! Improver patch application against the canonical skill/plugin sources.
//!
//! The improver role is the only actor allowed to rewrite files under
//! `agents/skills/`, `agents/plugins/`, and `local-skills/claude/`. The
//! helpers in this module canonicalize and guard the target path, back up
//! the original before writing, skip no-op rewrites, and atomically
//! replace the file on success.
#![allow(
    dead_code,
    reason = "review_mutations + improver HTTP handler consume these in Slice 3/4"
)]

use std::fs;
use std::path::{Component, Path, PathBuf};

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use similar::TextDiff;

use crate::errors::{CliError, CliErrorKind, io_for};
use crate::infra::io::write_text;

/// Canonical writeable targets for improver patches.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "snake_case")]
pub enum ImproverTarget {
    Skill,
    Plugin,
    LocalSkillClaude,
}

impl ImproverTarget {
    fn subdir(self) -> &'static str {
        match self {
            Self::Skill => "agents/skills",
            Self::Plugin => "agents/plugins",
            Self::LocalSkillClaude => "local-skills/claude",
        }
    }
}

/// Result of [`apply_improver_apply`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImproverApplyOutcome {
    pub canonical_path: PathBuf,
    pub before_sha256: String,
    pub after_sha256: String,
    pub applied: bool,
    pub backup_path: Option<PathBuf>,
    pub unified_diff: String,
}

/// Canonicalize `rel` under `repo_root/<target-subdir>` and reject any
/// path that escapes the target root, that is absolute, or that contains
/// `..` / prefix / root components.
///
/// Symlink escapes are caught because `canonicalize` resolves symlinks
/// before the `starts_with` check.
///
/// # Errors
/// Returns [`CliError`] when the path is absolute, escapes the root,
/// points outside the target subdirectory, or cannot be canonicalized.
pub fn validate_skill_patch_path(
    repo_root: &Path,
    target: ImproverTarget,
    rel: &Path,
) -> Result<PathBuf, CliError> {
    if rel.as_os_str().is_empty() {
        return Err(CliErrorKind::usage_error("improver path must not be empty".to_string()).into());
    }
    if rel.is_absolute() {
        return Err(CliErrorKind::usage_error(format!(
            "improver path must be relative: {}",
            rel.display()
        ))
        .into());
    }
    for comp in rel.components() {
        match comp {
            Component::Normal(_) | Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(CliErrorKind::usage_error(format!(
                    "improver path contains disallowed component: {}",
                    rel.display()
                ))
                .into());
            }
        }
    }

    let allowed_root = repo_root.join(target.subdir());
    let canonical_root = fs::canonicalize(&allowed_root)
        .map_err(|e| CliError::from(io_for("canonicalize", &allowed_root, &e)))?;
    let candidate = allowed_root.join(rel);
    let canonical = fs::canonicalize(&candidate)
        .map_err(|e| CliError::from(io_for("canonicalize", &candidate, &e)))?;
    if !canonical.starts_with(&canonical_root) {
        return Err(CliErrorKind::usage_error(format!(
            "improver path escapes allowed root {}: {}",
            canonical_root.display(),
            canonical.display()
        ))
        .into());
    }
    Ok(canonical)
}

/// Apply `new_contents` to the file at `rel` under the improver's target
/// root. Skip the write when the SHA-256 matches the current file. On
/// change, back up the original to
/// `<repo_root>/.harness-cache/improver-backups/<issue_id>.<ts>.bak`
/// and atomically rename a temp file into place.
///
/// # Errors
/// Returns [`CliError`] when the path fails validation, the target file
/// is missing, the backup write fails, or the atomic rename fails.
pub fn apply_improver_apply(
    repo_root: &Path,
    target: ImproverTarget,
    rel: &Path,
    new_contents: &str,
    issue_id: &str,
    now: &str,
) -> Result<ImproverApplyOutcome, CliError> {
    let canonical = validate_skill_patch_path(repo_root, target, rel)?;
    let existing = fs::read(&canonical)
        .map_err(|e| CliError::from(io_for("read", &canonical, &e)))?;
    let existing_text: String = String::from_utf8_lossy(&existing).into_owned();
    let new_contents_owned: String = new_contents.to_string();
    let before = sha256_hex(&existing);
    let after = sha256_hex(new_contents.as_bytes());
    let rel_display = rel.display().to_string();
    let unified_diff = TextDiff::from_lines(&existing_text, &new_contents_owned)
        .unified_diff()
        .header(&rel_display, &rel_display)
        .to_string();

    if before == after {
        return Ok(ImproverApplyOutcome {
            canonical_path: canonical,
            before_sha256: before,
            after_sha256: after,
            applied: false,
            backup_path: None,
            unified_diff,
        });
    }

    let backup_dir = repo_root.join(".harness-cache").join("improver-backups");
    fs::create_dir_all(&backup_dir)
        .map_err(|e| CliError::from(io_for("create_dir_all", &backup_dir, &e)))?;
    let backup_name = format!("{}.{}.bak", sanitize(issue_id), sanitize(now));
    let backup_path = backup_dir.join(backup_name);
    fs::write(&backup_path, &existing)
        .map_err(|e| CliError::from(io_for("write backup", &backup_path, &e)))?;

    write_text(&canonical, new_contents)?;

    Ok(ImproverApplyOutcome {
        canonical_path: canonical,
        before_sha256: before,
        after_sha256: after,
        applied: true,
        backup_path: Some(backup_path),
        unified_diff,
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn sanitize(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    fn seed_repo(target: ImproverTarget) -> (TempDir, PathBuf) {
        let dir = TempDir::new().expect("tempdir");
        let sub = dir.path().join(target.subdir());
        fs::create_dir_all(&sub).expect("create target dir");
        (dir, sub)
    }

    fn write_file(path: &Path, text: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("mkparent");
        }
        fs::write(path, text).expect("write");
    }

    #[test]
    fn validates_nested_relative_path_under_target_root() {
        let (repo, sub) = seed_repo(ImproverTarget::Skill);
        let target_file = sub.join("harness/SKILL.md");
        write_file(&target_file, "old\n");
        let canon = validate_skill_patch_path(
            repo.path(),
            ImproverTarget::Skill,
            Path::new("harness/SKILL.md"),
        )
        .expect("validate");
        assert_eq!(canon, fs::canonicalize(&target_file).unwrap());
    }

    #[test]
    fn rejects_absolute_paths() {
        let (repo, _) = seed_repo(ImproverTarget::Plugin);
        let err = validate_skill_patch_path(
            repo.path(),
            ImproverTarget::Plugin,
            Path::new("/etc/passwd"),
        )
        .unwrap_err();
        assert!(err.to_string().contains("must be relative"));
    }

    #[test]
    fn rejects_parent_traversal_in_relative_path() {
        let (repo, _) = seed_repo(ImproverTarget::Skill);
        let err = validate_skill_patch_path(
            repo.path(),
            ImproverTarget::Skill,
            Path::new("../../etc/passwd"),
        )
        .unwrap_err();
        assert!(err.to_string().contains("disallowed component"));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_escaping_allowed_root() {
        let (repo, sub) = seed_repo(ImproverTarget::LocalSkillClaude);
        let outside = repo.path().join("outside.md");
        write_file(&outside, "secret\n");
        let link = sub.join("leak.md");
        symlink(&outside, &link).expect("symlink");
        let err = validate_skill_patch_path(
            repo.path(),
            ImproverTarget::LocalSkillClaude,
            Path::new("leak.md"),
        )
        .unwrap_err();
        assert!(err.to_string().contains("escapes allowed root"));
    }

    #[test]
    fn apply_writes_new_contents_and_backs_up_original() {
        let (repo, sub) = seed_repo(ImproverTarget::Skill);
        let file = sub.join("SKILL.md");
        write_file(&file, "old body\n");
        let outcome = apply_improver_apply(
            repo.path(),
            ImproverTarget::Skill,
            Path::new("SKILL.md"),
            "new body\n",
            "issue-1",
            "2026-04-24T00:00:00Z",
        )
        .expect("apply");
        assert!(outcome.applied);
        assert_ne!(outcome.before_sha256, outcome.after_sha256);
        let on_disk = fs::read_to_string(&file).expect("read");
        assert_eq!(on_disk, "new body\n");
        let backup = outcome.backup_path.expect("backup path");
        assert!(backup.exists());
        let backup_contents = fs::read_to_string(&backup).expect("read backup");
        assert_eq!(backup_contents, "old body\n");
        assert!(outcome.unified_diff.contains("-old body"));
    }

    #[test]
    fn apply_is_idempotent_when_contents_match() {
        let (repo, sub) = seed_repo(ImproverTarget::Plugin);
        let file = sub.join("plugin.md");
        write_file(&file, "same\n");
        let outcome = apply_improver_apply(
            repo.path(),
            ImproverTarget::Plugin,
            Path::new("plugin.md"),
            "same\n",
            "issue-2",
            "ts",
        )
        .expect("apply");
        assert!(!outcome.applied);
        assert_eq!(outcome.before_sha256, outcome.after_sha256);
        assert!(outcome.backup_path.is_none());
        let backups = repo.path().join(".harness-cache").join("improver-backups");
        assert!(
            !backups.exists()
                || fs::read_dir(&backups).unwrap().next().is_none(),
            "no backup should be created on no-op apply"
        );
    }

    #[test]
    fn apply_rejects_missing_target_file() {
        let (repo, _) = seed_repo(ImproverTarget::Skill);
        let err = apply_improver_apply(
            repo.path(),
            ImproverTarget::Skill,
            Path::new("missing.md"),
            "x\n",
            "issue",
            "ts",
        )
        .unwrap_err();
        assert!(err.to_string().to_lowercase().contains("canonicalize"));
    }
}
