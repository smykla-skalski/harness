//! gix-backed unified-diff text generator (no `git diff` shell-out).
//!
//! Given a bare clone resolved by [`LocalCloneRuntime::ensure_clone`], plus
//! `base_oid` and `head_oid` resolved by the caller, produces a vec of
//! [`ReviewFilePatch`] rows with hunk text already formatted in
//! git's unified-diff shape so the Monitor's `SyntaxHighlightCache` can
//! tokenize them under `.diff` language with zero post-processing.
//!
//! Uses `gix::diff::blob::diff` + `UnifiedDiffBuilder` (re-export of
//! `imara-diff`) so the entire pipeline is SDK-driven. Binary files are
//! detected via the standard "NUL in first 8KB" heuristic git itself uses
//! and surfaced with `patch == ""` plus zero additions / deletions.

use std::collections::HashSet;
use std::io;
use std::path::Path;
use std::str::from_utf8;

use gix::ObjectId;
use gix::diff::blob::{
    Algorithm, InternedInput, UnifiedDiff, diff_with_slider_heuristics,
    unified_diff::{ConsumeHunk, ContextSize, DiffLineKind, HunkHeader},
};
use gix::object::tree::diff::ChangeDetached;
use tokio::task::spawn_blocking;

use crate::workspace::utc_now;

use super::local_clone_runtime::{EnsuredClone, LocalCloneRuntimeError};
use super::{ReviewFileChangeType, ReviewFilePatch, ReviewFileServedBy};

/// Threshold matching git's own binary heuristic. A blob whose first
/// 8KB contains a NUL byte is treated as binary; we emit a placeholder
/// patch (no hunks) so the UI can render a "Binary file" affordance.
const BINARY_SAMPLE_BYTES: usize = 8 * 1024;

/// Compute per-file unified-diff patches between two commits in `ensured`.
///
/// `path_filter`, when `Some(...)`, restricts output to those repo-relative
/// paths. `None` means "every changed file". Binary files always appear in
/// the output with `patch == ""` so the caller can show a placeholder.
///
/// # Errors
/// Returns [`LocalCloneRuntimeError`] on open / OID parse / object lookup
/// failures.
pub async fn compute_unified_patches(
    ensured: &EnsuredClone,
    base_oid: &str,
    head_oid: &str,
    path_filter: Option<&[String]>,
) -> Result<Vec<ReviewFilePatch>, LocalCloneRuntimeError> {
    let bare_path = ensured.bare_path.clone();
    let base = base_oid.to_string();
    let head = head_oid.to_string();
    let filter: Option<HashSet<String>> = path_filter.map(|paths| paths.iter().cloned().collect());
    spawn_blocking(move || run_compute(&bare_path, &base, &head, filter.as_ref()))
        .await
        .map_err(|join| LocalCloneRuntimeError::Join(join.to_string()))?
}

fn run_compute(
    bare_path: &Path,
    base_oid: &str,
    head_oid: &str,
    filter: Option<&HashSet<String>>,
) -> Result<Vec<ReviewFilePatch>, LocalCloneRuntimeError> {
    let repo = gix::open(bare_path).map_err(|e| LocalCloneRuntimeError::Open(e.to_string()))?;
    let base_object_id = ObjectId::from_hex(base_oid.as_bytes())
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;
    let head_object_id = ObjectId::from_hex(head_oid.as_bytes())
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;
    let base_tree = repo
        .find_object(base_object_id)
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?
        .try_into_commit()
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?
        .tree()
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;
    let head_tree = repo
        .find_object(head_object_id)
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?
        .try_into_commit()
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?
        .tree()
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;

    let changes = repo
        .diff_tree_to_tree(Some(&base_tree), Some(&head_tree), None)
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;

    let fetched_at = utc_now();
    let mut patches = Vec::with_capacity(changes.len());
    for change in changes {
        if let Some(patch) = patch_for_change(&repo, change, filter, &fetched_at, head_oid)? {
            patches.push(patch);
        }
    }
    Ok(patches)
}

/// Destructure a single [`ChangeDetached`] into the repo-relative path, the
/// before/after blob OIDs (each `None` for add/delete), and the mapped
/// [`ReviewFileChangeType`]. Pulled out of [`patch_for_change`] to keep that
/// function under the clippy `too_many_lines` threshold.
fn change_components(
    change: ChangeDetached,
) -> (
    String,
    Option<ObjectId>,
    Option<ObjectId>,
    ReviewFileChangeType,
) {
    match change {
        ChangeDetached::Addition { location, id, .. } => (
            String::from_utf8_lossy(&location).to_string(),
            None,
            Some(id),
            ReviewFileChangeType::Added,
        ),
        ChangeDetached::Deletion { location, id, .. } => (
            String::from_utf8_lossy(&location).to_string(),
            Some(id),
            None,
            ReviewFileChangeType::Deleted,
        ),
        ChangeDetached::Modification {
            location,
            previous_id,
            id,
            ..
        } => (
            String::from_utf8_lossy(&location).to_string(),
            Some(previous_id),
            Some(id),
            ReviewFileChangeType::Modified,
        ),
        ChangeDetached::Rewrite {
            location,
            source_id,
            id,
            ..
        } => (
            String::from_utf8_lossy(&location).to_string(),
            Some(source_id),
            Some(id),
            ReviewFileChangeType::Renamed,
        ),
    }
}

fn patch_for_change(
    repo: &gix::Repository,
    change: ChangeDetached,
    filter: Option<&HashSet<String>>,
    fetched_at: &str,
    head_ref_oid: &str,
) -> Result<Option<ReviewFilePatch>, LocalCloneRuntimeError> {
    let (path, before_id, after_id, status) = change_components(change);

    if let Some(filter) = filter
        && !filter.contains(&path)
    {
        return Ok(None);
    }

    let before_bytes = load_optional_blob(repo, before_id.as_ref())?;
    let after_bytes = load_optional_blob(repo, after_id.as_ref())?;

    let is_binary = looks_binary(&before_bytes) || looks_binary(&after_bytes);
    let (patch_text, additions, deletions) = if is_binary {
        (String::new(), 0_u32, 0_u32)
    } else {
        render_unified_diff(&before_bytes, &after_bytes)
    };

    Ok(Some(ReviewFilePatch {
        path,
        patch: patch_text,
        status,
        additions,
        deletions,
        truncated: false,
        etag: None,
        served_by: ReviewFileServedBy::LocalClone,
        fetched_at: fetched_at.to_string(),
        head_ref_oid: head_ref_oid.to_string(),
    }))
}

fn load_optional_blob(
    repo: &gix::Repository,
    id: Option<&ObjectId>,
) -> Result<Vec<u8>, LocalCloneRuntimeError> {
    let Some(id) = id else { return Ok(Vec::new()) };
    let obj = repo
        .find_object(*id)
        .map_err(|e| LocalCloneRuntimeError::BlobMissing(e.to_string()))?;
    Ok(obj.detach().data)
}

fn looks_binary(bytes: &[u8]) -> bool {
    let sample_len = bytes.len().min(BINARY_SAMPLE_BYTES);
    bytes[..sample_len].contains(&0u8)
}

fn render_unified_diff(before: &[u8], after: &[u8]) -> (String, u32, u32) {
    let before_str = from_utf8(before).unwrap_or("");
    let after_str = from_utf8(after).unwrap_or("");
    let input = InternedInput::new(before_str, after_str);
    let diff = diff_with_slider_heuristics(Algorithm::Histogram, &input);
    // gix-diff exposes a `ConsumeHunk` trait. We implement it inline so
    // hunks stream into a single String in standard `diff -u` shape:
    // `@@ -before_start,len +after_start,len @@`, with `-` / `+` / ` `
    // prefixes for removed / added / context lines.
    let consumer = StringHunkSink::default();
    let ud = UnifiedDiff::new(&diff, &input, consumer, ContextSize::symmetrical(3));
    let text = ud.consume().unwrap_or_default();
    let (additions, deletions) = count_add_del(&text);
    (text, additions, deletions)
}

/// In-process `ConsumeHunk` impl that buffers every hunk into a single
/// `String`. Built once per file, consumed once - no reuse across files.
#[derive(Default)]
struct StringHunkSink {
    buf: String,
}

impl ConsumeHunk for StringHunkSink {
    type Out = String;

    fn consume_hunk(
        &mut self,
        header: HunkHeader,
        lines: &[(DiffLineKind, &[u8])],
    ) -> io::Result<()> {
        use std::fmt::Write as _;
        let _ = writeln!(
            &mut self.buf,
            "@@ -{},{} +{},{} @@",
            header.before_hunk_start,
            header.before_hunk_len,
            header.after_hunk_start,
            header.after_hunk_len,
        );
        for (kind, content) in lines {
            let prefix = match kind {
                DiffLineKind::Context => ' ',
                DiffLineKind::Add => '+',
                DiffLineKind::Remove => '-',
            };
            self.buf.push(prefix);
            self.buf.push_str(&String::from_utf8_lossy(content));
            if !content.ends_with(b"\n") {
                self.buf.push('\n');
            }
        }
        Ok(())
    }

    fn finish(self) -> Self::Out {
        self.buf
    }
}

fn count_add_del(diff_text: &str) -> (u32, u32) {
    let mut adds = 0_u32;
    let mut dels = 0_u32;
    for line in diff_text.lines() {
        if line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        if line.starts_with('+') {
            adds = adds.saturating_add(1);
        } else if line.starts_with('-') {
            dels = dels.saturating_add(1);
        }
    }
    (adds, dels)
}

#[cfg(test)]
#[path = "local_clone_diff_tests.rs"]
mod tests;
