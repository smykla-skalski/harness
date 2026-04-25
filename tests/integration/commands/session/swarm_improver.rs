//! Integration coverage for the improver path guards, idempotent
//! apply, and rollback-on-failed-post-write semantics.

use std::fs;
use std::path::Path;

use harness::session::service::{ImproverTarget, apply_improver_apply, validate_skill_patch_path};

fn seed_skill(repo: &Path, rel: &str, contents: &str) -> std::path::PathBuf {
    let target = repo.join("agents/skills").join(rel);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(&target, contents).unwrap();
    target
}

#[test]
fn validate_rejects_absolute_path_even_under_skills_root() {
    let tmp = tempfile::tempdir().unwrap();
    seed_skill(tmp.path(), "placeholder.md", "x");
    let err =
        validate_skill_patch_path(tmp.path(), ImproverTarget::Skill, Path::new("/etc/passwd"))
            .unwrap_err();
    assert!(err.to_string().contains("must be relative"));
}

#[test]
fn validate_rejects_parent_traversal() {
    let tmp = tempfile::tempdir().unwrap();
    seed_skill(tmp.path(), "placeholder.md", "x");
    let err = validate_skill_patch_path(
        tmp.path(),
        ImproverTarget::Skill,
        Path::new("../../etc/passwd"),
    )
    .unwrap_err();
    assert!(err.to_string().contains("disallowed component"));
}

#[cfg(unix)]
#[test]
fn validate_rejects_symlink_escape() {
    use std::os::unix::fs::symlink;
    let tmp = tempfile::tempdir().unwrap();
    seed_skill(tmp.path(), "placeholder.md", "x");
    let outside = tmp.path().join("secrets.md");
    fs::write(&outside, "secret").unwrap();
    symlink(&outside, tmp.path().join("agents/skills/leak.md")).unwrap();
    let err = validate_skill_patch_path(tmp.path(), ImproverTarget::Skill, Path::new("leak.md"))
        .unwrap_err();
    assert!(err.to_string().contains("escapes allowed root"));
}

#[test]
fn apply_is_idempotent_on_same_contents() {
    let tmp = tempfile::tempdir().unwrap();
    seed_skill(tmp.path(), "SKILL.md", "body\n");
    let outcome = apply_improver_apply(
        tmp.path(),
        ImproverTarget::Skill,
        Path::new("SKILL.md"),
        "body\n",
        "issue-idem",
        "2026-04-24T00:00:00Z",
    )
    .unwrap();
    assert!(!outcome.applied, "no-op on matching sha");
    assert!(outcome.backup_path.is_none(), "no backup on no-op");
    let backups_root = tmp.path().join(".harness-cache/improver-backups");
    assert!(
        !backups_root.exists() || fs::read_dir(&backups_root).unwrap().next().is_none(),
        "no backup files written for idempotent apply"
    );
}

#[test]
fn apply_writes_and_backs_up_original() {
    let tmp = tempfile::tempdir().unwrap();
    let target = seed_skill(tmp.path(), "SKILL.md", "old\n");
    let outcome = apply_improver_apply(
        tmp.path(),
        ImproverTarget::Skill,
        Path::new("SKILL.md"),
        "new\n",
        "issue-update",
        "2026-04-24T00:00:00Z",
    )
    .unwrap();
    assert!(outcome.applied);
    assert_ne!(outcome.before_sha256, outcome.after_sha256);
    assert_eq!(fs::read_to_string(&target).unwrap(), "new\n");
    let backup = outcome.backup_path.expect("backup written");
    assert_eq!(fs::read_to_string(&backup).unwrap(), "old\n");
    assert!(
        outcome.unified_diff.contains("-old") && outcome.unified_diff.contains("+new"),
        "unified_diff must show the change"
    );
}

#[cfg(unix)]
#[test]
fn failed_write_rolls_back_to_original_contents() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let target = seed_skill(tmp.path(), "SKILL.md", "pristine\n");
    // Lock the parent directory read-only so write_text's rename fails
    // after the validation + backup succeed. On unix, chmod 0555 denies
    // the tempfile rename into the target directory.
    let skills_dir = tmp.path().join("agents/skills");
    let prev = fs::metadata(&skills_dir).unwrap().permissions();
    fs::set_permissions(&skills_dir, fs::Permissions::from_mode(0o555)).unwrap();

    let result = apply_improver_apply(
        tmp.path(),
        ImproverTarget::Skill,
        Path::new("SKILL.md"),
        "rewrite\n",
        "issue-rollback",
        "2026-04-24T00:00:00Z",
    );

    // Restore permissions before asserting so the temp dir can clean up.
    fs::set_permissions(&skills_dir, prev).unwrap();

    assert!(result.is_err(), "locked parent must fail the write");
    let on_disk = fs::read_to_string(&target).unwrap();
    assert_eq!(
        on_disk, "pristine\n",
        "rollback must restore the original contents"
    );
}
