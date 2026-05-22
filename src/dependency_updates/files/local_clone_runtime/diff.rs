use std::collections::BTreeSet;
use std::ops::ControlFlow;

use chrono::Utc;
use gix::bstr::ByteSlice;
use gix::object::tree::diff::Change;

use super::{EnsuredClone, LocalCloneRuntime, LocalCloneRuntimeError, resolve_ref};
use crate::dependency_updates::files::{
    DependencyUpdateFileChangeType, DependencyUpdateFilePatch, DependencyUpdateFileServedBy,
};

/// Exact remote ref to fetch into a deterministic local tracking ref.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalCloneFetchRef {
    pub remote_ref: String,
    pub local_ref: String,
}

impl LocalCloneFetchRef {
    #[must_use]
    pub fn new(remote_ref: impl Into<String>, local_ref: impl Into<String>) -> Self {
        Self {
            remote_ref: remote_ref.into(),
            local_ref: local_ref.into(),
        }
    }

    #[must_use]
    pub fn mirrored(remote_ref: impl Into<String>) -> Self {
        let remote_ref = remote_ref.into();
        let local_ref = local_tracking_ref_for(&remote_ref);
        Self::new(remote_ref, local_ref)
    }

    #[must_use]
    pub fn github_pull_head(number: u64) -> Self {
        Self::mirrored(format!("refs/pull/{number}/head"))
    }

    #[must_use]
    pub fn refspec(&self) -> String {
        format!("+{}:{}", self.remote_ref, self.local_ref)
    }
}

/// Summary of a merge-base diff computed from the local bare clone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalCloneDiff {
    pub base_ref_oid: String,
    pub head_ref_oid: String,
    pub merge_base_oid: String,
    pub stats: LocalCloneDiffStats,
    pub patches: Vec<DependencyUpdateFilePatch>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LocalCloneDiffStats {
    pub files_changed: u32,
    pub additions: u32,
    pub deletions: u32,
}

impl LocalCloneRuntime {
    /// Diff `merge-base(base_ref, head_ref)..head_ref` using only the local
    /// clone. `paths` narrows output to exact old or new paths when nonempty.
    ///
    /// # Errors
    /// Returns [`LocalCloneRuntimeError`] when refs cannot be resolved, no
    /// merge base exists, or gix cannot diff the commit trees.
    pub async fn diff_refs(
        &self,
        ensured: &EnsuredClone,
        base_ref: &str,
        head_ref: &str,
        paths: &[String],
    ) -> Result<LocalCloneDiff, LocalCloneRuntimeError> {
        let bare_path = ensured.bare_path.clone();
        let base_ref = base_ref.to_string();
        let head_ref = head_ref.to_string();
        let requested = paths.iter().cloned().collect::<BTreeSet<_>>();
        tokio::task::spawn_blocking(move || {
            run_diff_refs(bare_path, &base_ref, &head_ref, &requested)
        })
        .await
        .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?
    }
}

fn run_diff_refs(
    bare_path: std::path::PathBuf,
    base_ref: &str,
    head_ref: &str,
    requested: &BTreeSet<String>,
) -> Result<LocalCloneDiff, LocalCloneRuntimeError> {
    let repo = gix::open(&bare_path).map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
    let base_oid = resolve_ref(&repo, base_ref)?;
    let head_oid = resolve_ref(&repo, head_ref)?;
    let merge_base = repo
        .merge_base(base_oid, head_oid)
        .map_err(|e| LocalCloneRuntimeError::MergeBase(e.to_string()))?
        .detach();
    let base_tree = repo
        .find_object(merge_base)
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?
        .peel_to_tree()
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?;
    let head_tree = repo
        .find_object(head_oid)
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?
        .peel_to_tree()
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?;
    let fetched_at = Utc::now().to_rfc3339();
    let mut blob_cache = repo
        .diff_resource_cache_for_tree_diff()
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?;
    let mut patches = Vec::new();
    base_tree
        .changes()
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?
        .options(|opts| {
            opts.track_path().track_rewrites(None);
        })
        .for_each_to_obtain_tree(&head_tree, |change| {
            if change_matches(&change, requested) {
                patches.push(patch_for_change(
                    &change,
                    &mut blob_cache,
                    &fetched_at,
                    &head_oid.to_hex().to_string(),
                )?);
                blob_cache.clear_resource_cache_keep_allocation();
            }
            Ok::<_, LocalCloneRuntimeError>(ControlFlow::Continue(()))
        })
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?;
    let stats = stats_for(&patches);
    Ok(LocalCloneDiff {
        base_ref_oid: base_oid.to_hex().to_string(),
        head_ref_oid: head_oid.to_hex().to_string(),
        merge_base_oid: merge_base.to_hex().to_string(),
        stats,
        patches,
    })
}

fn patch_for_change(
    change: &Change<'_, '_, '_>,
    blob_cache: &mut gix::diff::blob::Platform,
    fetched_at: &str,
    head_oid: &str,
) -> Result<DependencyUpdateFilePatch, LocalCloneRuntimeError> {
    let paths = change_paths(change);
    let hunk = render_hunks(change, blob_cache, &paths)?;
    let (additions, deletions) = count_patch_lines(&hunk);
    Ok(DependencyUpdateFilePatch {
        path: paths.new_path.clone(),
        patch: render_patch(change, &paths, &hunk),
        status: change_status(change),
        additions,
        deletions,
        truncated: false,
        etag: None,
        served_by: DependencyUpdateFileServedBy::LocalClone,
        fetched_at: fetched_at.to_string(),
        head_ref_oid: head_oid.to_string(),
    })
}

fn render_hunks(
    change: &Change<'_, '_, '_>,
    blob_cache: &mut gix::diff::blob::Platform,
    paths: &ChangePaths,
) -> Result<String, LocalCloneRuntimeError> {
    let platform = change
        .diff(blob_cache)
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?;
    platform
        .resource_cache
        .options
        .skip_internal_diff_if_external_is_configured = false;
    let prepared = platform
        .resource_cache
        .prepare_diff()
        .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))?;
    match prepared.operation {
        gix::diff::blob::platform::prepare_diff::Operation::InternalDiff { algorithm } => {
            let input = prepared.interned_input();
            let diff = gix::diff::blob::Diff::compute(algorithm, &input);
            gix::diff::blob::UnifiedDiff::new(
                &diff,
                &input,
                gix::diff::blob::unified_diff::ConsumeBinaryHunk::new(String::new(), "\n"),
                gix::diff::blob::unified_diff::ContextSize::symmetrical(3),
            )
            .consume()
            .map_err(|e| LocalCloneRuntimeError::Diff(e.to_string()))
        }
        gix::diff::blob::platform::prepare_diff::Operation::SourceOrDestinationIsBinary => {
            Ok(format!(
                "Binary files a/{} and b/{} differ\n",
                paths.old_path, paths.new_path
            ))
        }
        gix::diff::blob::platform::prepare_diff::Operation::ExternalCommand { .. } => Err(
            LocalCloneRuntimeError::Diff("external diff command was not expected".to_string()),
        ),
    }
}

fn render_patch(change: &Change<'_, '_, '_>, paths: &ChangePaths, hunk: &str) -> String {
    let mut patch = format!("diff --git a/{} b/{}\n", paths.old_path, paths.new_path);
    match change {
        Change::Addition { .. } => patch.push_str("--- /dev/null\n"),
        _ => patch.push_str(&format!("--- a/{}\n", paths.old_path)),
    }
    match change {
        Change::Deletion { .. } => patch.push_str("+++ /dev/null\n"),
        _ => patch.push_str(&format!("+++ b/{}\n", paths.new_path)),
    }
    patch.push_str(hunk);
    patch
}

fn change_matches(change: &Change<'_, '_, '_>, requested: &BTreeSet<String>) -> bool {
    if requested.is_empty() {
        return true;
    }
    let paths = change_paths(change);
    requested.contains(&paths.old_path) || requested.contains(&paths.new_path)
}

fn change_status(change: &Change<'_, '_, '_>) -> DependencyUpdateFileChangeType {
    match change {
        Change::Addition { .. } => DependencyUpdateFileChangeType::Added,
        Change::Deletion { .. } => DependencyUpdateFileChangeType::Deleted,
        Change::Modification { .. } => DependencyUpdateFileChangeType::Modified,
        Change::Rewrite { copy, .. } => {
            if *copy {
                DependencyUpdateFileChangeType::Copied
            } else {
                DependencyUpdateFileChangeType::Renamed
            }
        }
    }
}

struct ChangePaths {
    old_path: String,
    new_path: String,
}

fn change_paths(change: &Change<'_, '_, '_>) -> ChangePaths {
    match change {
        Change::Addition { location, .. } => {
            let path = path_to_string(location);
            ChangePaths {
                old_path: path.clone(),
                new_path: path,
            }
        }
        Change::Deletion { location, .. } | Change::Modification { location, .. } => {
            let path = path_to_string(location);
            ChangePaths {
                old_path: path.clone(),
                new_path: path,
            }
        }
        Change::Rewrite {
            source_location,
            location,
            ..
        } => ChangePaths {
            old_path: path_to_string(source_location),
            new_path: path_to_string(location),
        },
    }
}

fn path_to_string(path: &gix::bstr::BStr) -> String {
    path.to_str_lossy().into_owned()
}

fn count_patch_lines(hunk: &str) -> (u32, u32) {
    hunk.lines().fold((0, 0), |(additions, deletions), line| {
        if line.starts_with('+') && !line.starts_with("+++") {
            (additions + 1, deletions)
        } else if line.starts_with('-') && !line.starts_with("---") {
            (additions, deletions + 1)
        } else {
            (additions, deletions)
        }
    })
}

fn stats_for(patches: &[DependencyUpdateFilePatch]) -> LocalCloneDiffStats {
    LocalCloneDiffStats {
        files_changed: patches.len().try_into().unwrap_or(u32::MAX),
        additions: patches.iter().map(|patch| patch.additions).sum(),
        deletions: patches.iter().map(|patch| patch.deletions).sum(),
    }
}

fn local_tracking_ref_for(remote_ref: &str) -> String {
    let suffix = remote_ref.strip_prefix("refs/").unwrap_or(remote_ref);
    let suffix = suffix
        .chars()
        .map(|ch| match ch {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '/' | '-' | '_' | '.' => ch,
            _ => '_',
        })
        .collect::<String>();
    format!("refs/harness/dependency-updates/{suffix}")
}
