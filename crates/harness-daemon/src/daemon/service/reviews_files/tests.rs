//! Unit tests for the reviews-files service endpoints.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use crate::reviews::{
    LocalCloneRegistry, LocalCloneRoot, ReviewFileViewedState, ReviewFilesViewedTarget,
    ReviewsFilesBlobRequest, ReviewsFilesListRequest, ReviewsFilesPatchRequest,
    ReviewsFilesViewedRequest,
};

use super::clones::{clones_root, load_registry, save_registry};
use super::gc::{apply_local_clone_gc_targets, run_local_clone_gc_with};
use super::patch::local_clone_fetch_context;
use super::{
    GcReport, delete_review_local_clone, fetch_review_file_blob, list_review_files,
    list_review_local_clones, mark_review_files_viewed, patch_review_files,
};

#[tokio::test]
async fn list_request_rejects_empty_pull_request_id() {
    let request = ReviewsFilesListRequest {
        pull_request_id: "   ".into(),
        force_refresh: false,
    };
    let err = list_review_files(&request).await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("pull_request_id"));
}

#[tokio::test]
async fn patch_request_rejects_empty_pull_request_id() {
    let request = ReviewsFilesPatchRequest {
        pull_request_id: "".into(),
        head_ref_oid_expected: "abc".into(),
        paths: vec!["src/lib.rs".into()],
        number: None,
        repository_full_name: None,
        base_ref_oid_expected: None,
        head_ref_name: None,
        base_ref_name: None,
        large_diff_strategy: None,
    };
    let err = patch_review_files(&request).await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("pull_request_id"));
}

#[tokio::test]
async fn patch_request_returns_empty_patches_when_context_is_missing() {
    let request = ReviewsFilesPatchRequest {
        pull_request_id: "PR_1".into(),
        head_ref_oid_expected: "abc".into(),
        paths: vec!["src/lib.rs".into()],
        number: None,
        repository_full_name: None,
        base_ref_oid_expected: None,
        head_ref_name: None,
        base_ref_name: None,
        large_diff_strategy: None,
    };
    let response = patch_review_files(&request).await.expect("ok");
    assert_eq!(response.pull_request_id, "PR_1");
    assert!(response.patches.is_empty());
    assert!(!response.drifted);
    assert_eq!(response.current_head_ref_oid, "abc");
}

#[tokio::test]
async fn viewed_request_rejects_empty_paths() {
    let request = ReviewsFilesViewedRequest {
        pull_request_id: "PR_1".into(),
        paths: vec![],
    };
    let err = mark_review_files_viewed(&request).await.unwrap_err();
    assert!(err.to_string().contains("path"));
}

#[tokio::test]
async fn blob_request_rejects_empty_oid() {
    let request = ReviewsFilesBlobRequest {
        repository_id: "MDEwOlJlcG9zaXRvcnk".into(),
        oid: "".into(),
        path: "logo.png".into(),
    };
    let err = fetch_review_file_blob(&request).await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("oid"));
}

#[tokio::test]
async fn local_clones_returns_empty_when_registry_missing() {
    // The daemon_root() in test mode points at a tmp dir so the registry
    // file is absent until something writes it; the handler must return
    // Ok(vec![]) rather than an error.
    let response = list_review_local_clones().await.expect("ok");
    assert!(response.is_empty());
}

#[test]
fn local_clone_fetch_context_prefers_github_pull_ref() {
    let (refs, head_ref) = local_clone_fetch_context(Some(7), Some("renovate/foo"), Some("main"));

    assert_eq!(head_ref, "refs/harness/reviews/pull/7/head");
    assert!(refs.iter().any(|r| r.remote_ref == "refs/pull/7/head"));
    assert!(refs.iter().any(|r| r.remote_ref == "refs/heads/main"));
}

#[test]
fn local_clone_fetch_context_uses_branch_when_number_missing() {
    let (refs, head_ref) = local_clone_fetch_context(None, Some("renovate/foo"), None);

    assert_eq!(head_ref, "refs/harness/reviews/heads/renovate/foo");
    assert_eq!(refs.len(), 1);
    assert_eq!(refs[0].remote_ref, "refs/heads/renovate/foo");
}

#[test]
fn viewed_target_helper_constructs_normalized_payload() {
    // Sanity check that the viewed-target struct is constructible from
    // the public type re-export so the service compiles against the
    // protocol surface as well as the file-module internal one.
    let target = ReviewFilesViewedTarget {
        path: "src/lib.rs".into(),
        expected_prior_state: ReviewFileViewedState::Unviewed,
        mark_viewed: true,
    };
    assert_eq!(target.path, "src/lib.rs");
    assert!(target.mark_viewed);
}

#[tokio::test]
async fn delete_local_clone_rejects_empty_segment() {
    let err = delete_review_local_clone("   ").await.unwrap_err();
    assert!(err.to_string().to_lowercase().contains("repo_key_segment"));
}

#[test]
fn clones_root_is_under_daemon_root() {
    let root = clones_root();
    assert!(
        root.registry_path()
            .to_string_lossy()
            .ends_with("reviews/clones/registry.json")
    );
}

#[test]
fn save_then_load_registry_round_trips() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let root = LocalCloneRoot::new(tmp.path().to_path_buf());
    let mut registry = LocalCloneRegistry::default();
    registry.insert_or_update(
        crate::reviews::RepoKey::new("owner/repo"),
        crate::reviews::RegistryEntry {
            repo_full_name: "owner/repo".into(),
            bare_path: tmp.path().join("owner__repo.git"),
            size_bytes: 1024,
            created_at: chrono::Utc::now(),
            last_used_at: chrono::Utc::now(),
            last_fetched_at: chrono::Utc::now(),
            last_known_head_ref_oid_by_pr: BTreeMap::new(),
        },
    );
    save_registry(&root, &registry).expect("save");
    let loaded = load_registry(&root).expect("load");
    assert_eq!(loaded.entries.len(), 1);
}

#[test]
fn local_clone_gc_drops_registry_row_when_path_is_missing() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let key = crate::reviews::RepoKey::new("owner/repo");
    let mut registry = LocalCloneRegistry::default();
    registry.insert_or_update(
        key.clone(),
        gc_registry_entry("owner/repo", tmp.path().join("missing.git"), 1024),
    );

    let report = apply_local_clone_gc_targets(&mut registry, &[key]);

    assert_eq!(report.targets, 1);
    assert_eq!(report.removed, 1);
    assert!(registry.entries.is_empty());
}

#[test]
fn local_clone_gc_retains_registry_row_when_delete_fails() {
    let tmp = tempfile::tempdir().expect("tmpdir");
    let key = crate::reviews::RepoKey::new("owner/repo");
    let bare_path = tmp.path().join("owner__repo.git");
    fs::write(&bare_path, b"not a directory").expect("fixture file");
    let mut registry = LocalCloneRegistry::default();
    registry.insert_or_update(
        key.clone(),
        gc_registry_entry("owner/repo", bare_path.clone(), 1024),
    );

    let report = apply_local_clone_gc_targets(&mut registry, &[key.clone()]);

    assert_eq!(report.targets, 1);
    assert_eq!(report.removed, 0);
    assert!(registry.entries.contains_key(&key));
    assert!(bare_path.exists());
}

fn gc_registry_entry(
    repo_full_name: &str,
    bare_path: PathBuf,
    size_bytes: u64,
) -> crate::reviews::RegistryEntry {
    crate::reviews::RegistryEntry {
        repo_full_name: repo_full_name.into(),
        bare_path,
        size_bytes,
        created_at: chrono::Utc::now(),
        last_used_at: chrono::Utc::now(),
        last_fetched_at: chrono::Utc::now(),
        last_known_head_ref_oid_by_pr: BTreeMap::new(),
    }
}

fn make_registry_entry(
    bare_path: &std::path::Path,
    repo_full_name: &str,
    size_bytes: u64,
) -> crate::reviews::RegistryEntry {
    gc_registry_entry(repo_full_name, bare_path.to_path_buf(), size_bytes)
}

#[test]
fn gc_drops_stale_entries_and_removes_bare_dirs() {
    use crate::reviews::files::local_clone::RepoKey;

    let tempdir = tempfile::tempdir().expect("tempdir");
    let root = LocalCloneRoot::new(tempdir.path().to_path_buf());
    std::fs::create_dir_all(&root.path).expect("mkdir root");

    // Old entry: last_used 60 days ago, bare dir actually present
    // on disk. Should be dropped + removed.
    let old_dir = root.path.join("old.git");
    std::fs::create_dir_all(&old_dir).expect("mkdir old");
    std::fs::write(old_dir.join("HEAD"), b"ref: refs/heads/main\n").expect("write");
    let old_key = RepoKey::new("o/old");
    let now = chrono::Utc::now();
    let mut old_entry = make_registry_entry(&old_dir, "o/old", 100);
    old_entry.last_used_at = now - chrono::Duration::days(60);
    old_entry.last_fetched_at = now - chrono::Duration::days(60);

    // Fresh entry: last_used today, bare dir present. Must survive.
    let fresh_dir = root.path.join("fresh.git");
    std::fs::create_dir_all(&fresh_dir).expect("mkdir fresh");
    std::fs::write(fresh_dir.join("HEAD"), b"ref: refs/heads/main\n").expect("write");
    let fresh_key = RepoKey::new("o/fresh");
    let fresh_entry = make_registry_entry(&fresh_dir, "o/fresh", 200);

    let mut registry = LocalCloneRegistry::default();
    registry.insert_or_update(old_key.clone(), old_entry);
    registry.insert_or_update(fresh_key.clone(), fresh_entry);
    save_registry(&root, &registry).expect("save");

    let report = run_local_clone_gc_with(
        &root,
        now,
        chrono::Duration::days(30),
        10 * 1024 * 1024 * 1024, // 10 GB - well above the 300 bytes we wrote
    )
    .expect("gc");
    assert_eq!(report.targets, 1, "exactly the old entry flagged");
    assert_eq!(report.removed, 1, "old bare dir removed");
    assert_eq!(report.bytes_freed, 100, "freed bytes match registry size");
    // Old dir gone; fresh dir intact.
    assert!(!old_dir.exists(), "old bare dir should be removed");
    assert!(fresh_dir.exists(), "fresh bare dir should be untouched");
    // Registry on disk reflects the deletion.
    let reloaded = load_registry(&root).expect("reload");
    assert_eq!(reloaded.entries.len(), 1);
    assert!(reloaded.entries.contains_key(&fresh_key));
    assert!(!reloaded.entries.contains_key(&old_key));
}

#[test]
fn gc_evicts_lru_until_under_disk_budget() {
    use crate::reviews::files::local_clone::RepoKey;

    let tempdir = tempfile::tempdir().expect("tempdir");
    let root = LocalCloneRoot::new(tempdir.path().to_path_buf());
    std::fs::create_dir_all(&root.path).expect("mkdir root");

    // Three entries, all fresh-by-age but cumulative size > budget.
    // Oldest-by-last_used should be evicted first.
    let now = chrono::Utc::now();
    let mut registry = LocalCloneRegistry::default();
    let keys: Vec<RepoKey> = (0..3).map(|i| RepoKey::new(format!("o/r{i}"))).collect();
    for (i, key) in keys.iter().enumerate() {
        let dir = root.path.join(format!("r{i}.git"));
        std::fs::create_dir_all(&dir).expect("mkdir");
        std::fs::write(dir.join("HEAD"), b"x\n").expect("write");
        let mut entry = make_registry_entry(&dir, &format!("o/r{i}"), 1_000);
        // Earlier index = older last_used (will be evicted first).
        entry.last_used_at = now - chrono::Duration::hours(i64::try_from(3 - i).unwrap_or(0));
        registry.insert_or_update(key.clone(), entry);
    }
    save_registry(&root, &registry).expect("save");

    // Budget = 1500 bytes, but we have 3 × 1000 = 3000.
    // Two oldest must be evicted.
    let report =
        run_local_clone_gc_with(&root, now, chrono::Duration::days(30), 1_500).expect("gc");
    assert_eq!(report.targets, 2, "two LRU evictions");
    assert_eq!(report.removed, 2, "two bare dirs removed");
    assert_eq!(report.bytes_freed, 2_000, "2 × 1000 bytes freed");
    let reloaded = load_registry(&root).expect("reload");
    assert_eq!(reloaded.entries.len(), 1);
    // The newest survives (last index in our setup).
    assert!(reloaded.entries.contains_key(&keys[2]));
}

#[test]
fn gc_returns_empty_report_when_under_thresholds() {
    let tempdir = tempfile::tempdir().expect("tempdir");
    let root = LocalCloneRoot::new(tempdir.path().to_path_buf());
    std::fs::create_dir_all(&root.path).expect("mkdir root");
    let registry = LocalCloneRegistry::default();
    save_registry(&root, &registry).expect("save");
    let now = chrono::Utc::now();
    let report =
        run_local_clone_gc_with(&root, now, chrono::Duration::days(30), u64::MAX).expect("gc");
    assert_eq!(report, GcReport::default());
}

#[test]
fn gc_tolerates_missing_bare_dir() {
    use crate::reviews::files::local_clone::RepoKey;

    let tempdir = tempfile::tempdir().expect("tempdir");
    let root = LocalCloneRoot::new(tempdir.path().to_path_buf());
    std::fs::create_dir_all(&root.path).expect("mkdir root");
    // Registry entry pointing at a path that doesn't exist - simulates
    // a clone that was manually rm -rf'd. GC should still drop the
    // registry row + count it as removed.
    let mut registry = LocalCloneRegistry::default();
    let now = chrono::Utc::now();
    let mut entry = make_registry_entry(&root.path.join("missing.git"), "o/ghost", 500);
    entry.last_used_at = now - chrono::Duration::days(60);
    registry.insert_or_update(RepoKey::new("o/ghost"), entry);
    save_registry(&root, &registry).expect("save");

    let report =
        run_local_clone_gc_with(&root, now, chrono::Duration::days(30), u64::MAX).expect("gc");
    assert_eq!(report.targets, 1);
    assert_eq!(report.removed, 1);
    // bytes_freed = 0 because no actual filesystem removal happened.
    assert_eq!(report.bytes_freed, 0);
}
