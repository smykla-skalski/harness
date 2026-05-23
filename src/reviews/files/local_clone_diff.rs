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
use super::{
    ReviewFileChangeType, ReviewFilePatch, ReviewFileServedBy,
};

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

#[allow(clippy::too_many_lines)]
fn patch_for_change(
    repo: &gix::Repository,
    change: ChangeDetached,
    filter: Option<&HashSet<String>>,
    fetched_at: &str,
    head_ref_oid: &str,
) -> Result<Option<ReviewFilePatch>, LocalCloneRuntimeError> {

    let (path, before_id, after_id, status) = match change {
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
    };

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
mod tests {
    use super::*;
    use crate::reviews::files::local_clone::LocalCloneRoot;
    use crate::reviews::files::local_clone_runtime::{
        DiscardProgressSink, LocalCloneProgressSink, LocalCloneRuntime,
    };
    use std::sync::Arc;

    // Write a fixed user identity into the repo's local config so commits don't
    // fall back to ~/.gitconfig when a parallel test redirects HOME via
    // temp_env::with_var.
    fn set_test_user(repo_path: &std::path::Path) {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(repo_path.join("config"))
            .expect("open repo config");
        writeln!(f, "[user]\n\tname = Test\n\temail = test@example.com")
            .expect("write user config");
    }

    /// Build a bare source repo with two commits: c0 establishes the
    /// initial state, c1 modifies one file, adds another, and deletes a
    /// third. Returns (c0, c1) so the tests can drive the diff between
    /// them.
    fn make_two_commit_source(path: &std::path::Path) -> (gix::ObjectId, gix::ObjectId) {
        gix::init_bare(path).expect("init bare");
        set_test_user(path);
        let repo = gix::open(path).expect("reopen bare");

        // c0: alpha.txt + delete-me.txt
        let alpha_v0 = repo
            .write_blob(b"alpha v0\nshared line\n" as &[u8])
            .expect("alpha v0")
            .detach();
        let delete_me = repo
            .write_blob(b"to delete\n" as &[u8])
            .expect("delete-me blob")
            .detach();
        let mut tree0 = gix::objs::Tree::empty();
        tree0.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "alpha.txt".into(),
            oid: alpha_v0,
        });
        tree0.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "delete-me.txt".into(),
            oid: delete_me,
        });
        let tree0_oid = repo.write_object(&tree0).expect("tree0").detach();
        let c0 = repo
            .commit(
                "refs/heads/main",
                "c0",
                tree0_oid,
                Vec::<gix::ObjectId>::new(),
            )
            .expect("c0")
            .detach();

        // c1: alpha modified, beta added, delete-me removed.
        let alpha_v1 = repo
            .write_blob(b"alpha v1\nshared line\nnew line\n" as &[u8])
            .expect("alpha v1")
            .detach();
        let beta = repo
            .write_blob(b"beta one\nbeta two\n" as &[u8])
            .expect("beta")
            .detach();
        let mut tree1 = gix::objs::Tree::empty();
        tree1.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "alpha.txt".into(),
            oid: alpha_v1,
        });
        tree1.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "beta.txt".into(),
            oid: beta,
        });
        let tree1_oid = repo.write_object(&tree1).expect("tree1").detach();
        let c1 = repo
            .commit("refs/heads/main", "c1", tree1_oid, vec![c0])
            .expect("c1")
            .detach();
        (c0, c1)
    }

    #[tokio::test]
    async fn compute_patches_emits_added_modified_deleted_rows() {
        let dir = tempfile::tempdir().expect("tempdir");
        let source = dir.path().join("source.git");
        let (c0, c1) = make_two_commit_source(&source);

        let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
        let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
        let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
        let url = format!("file://{}", source.display());
        let ensured = runtime
            .ensure_clone_with_url("fixture/source", &url, "refs/heads/main", sink)
            .await
            .expect("ensure clone");

        let patches = compute_unified_patches(
            &ensured,
            &c0.to_hex().to_string(),
            &c1.to_hex().to_string(),
            None,
        )
        .await
        .expect("compute patches");

        // Three entries: alpha (modified), beta (added), delete-me (deleted)
        assert_eq!(patches.len(), 3);
        let by_path: std::collections::BTreeMap<_, _> =
            patches.into_iter().map(|p| (p.path.clone(), p)).collect();
        assert_eq!(
            by_path["alpha.txt"].status,
            ReviewFileChangeType::Modified
        );
        assert_eq!(
            by_path["beta.txt"].status,
            ReviewFileChangeType::Added
        );
        assert_eq!(
            by_path["delete-me.txt"].status,
            ReviewFileChangeType::Deleted
        );
        // Modified row has both additions and deletions.
        assert!(by_path["alpha.txt"].additions > 0);
        assert!(by_path["alpha.txt"].deletions > 0);
        // All served via local clone.
        for patch in by_path.values() {
            assert_eq!(patch.served_by, ReviewFileServedBy::LocalClone);
            assert!(!patch.truncated);
        }
    }

    #[tokio::test]
    async fn compute_patches_respects_path_filter() {
        let dir = tempfile::tempdir().expect("tempdir");
        let source = dir.path().join("source.git");
        let (c0, c1) = make_two_commit_source(&source);

        let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
        let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
        let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
        let url = format!("file://{}", source.display());
        let ensured = runtime
            .ensure_clone_with_url("fixture/source", &url, "refs/heads/main", sink)
            .await
            .expect("ensure clone");

        let patches = compute_unified_patches(
            &ensured,
            &c0.to_hex().to_string(),
            &c1.to_hex().to_string(),
            Some(&["beta.txt".to_string()]),
        )
        .await
        .expect("compute filtered");

        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].path, "beta.txt");
    }

    #[tokio::test]
    async fn compute_patches_marks_binary_with_empty_patch() {
        let dir = tempfile::tempdir().expect("tempdir");
        let source = dir.path().join("source.git");
        gix::init_bare(&source).expect("init");
        set_test_user(&source);
        let repo = gix::open(&source).expect("reopen");
        let mut bin = Vec::from(b"PNG-like\0\x01\x02\x03" as &[u8]);
        bin.extend_from_slice(&[0u8; 32]);
        let bin_oid = repo.write_blob(bin.as_slice()).expect("bin").detach();
        let mut tree = gix::objs::Tree::empty();
        tree.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "logo.png".into(),
            oid: bin_oid,
        });
        let tree_oid = repo.write_object(&tree).expect("tree").detach();
        let c0 = repo
            .commit(
                "refs/heads/main",
                "c0",
                tree_oid,
                Vec::<gix::ObjectId>::new(),
            )
            .expect("c0")
            .detach();

        let mut bin2 = Vec::from(b"PNG-other\0\xff\xfe\xfd" as &[u8]);
        bin2.extend_from_slice(&[0u8; 32]);
        let bin_oid_v2 = repo.write_blob(bin2.as_slice()).expect("bin2").detach();
        let mut tree1 = gix::objs::Tree::empty();
        tree1.entries.push(gix::objs::tree::Entry {
            mode: gix::objs::tree::EntryKind::Blob.into(),
            filename: "logo.png".into(),
            oid: bin_oid_v2,
        });
        let tree1_oid = repo.write_object(&tree1).expect("tree1").detach();
        let c1 = repo
            .commit("refs/heads/main", "c1", tree1_oid, vec![c0])
            .expect("c1")
            .detach();

        let clones_root = LocalCloneRoot::new(dir.path().join("clones"));
        let runtime = Arc::new(LocalCloneRuntime::new(clones_root));
        let sink: Arc<dyn LocalCloneProgressSink> = Arc::new(DiscardProgressSink);
        let url = format!("file://{}", source.display());
        let ensured = runtime
            .ensure_clone_with_url("fixture/binary", &url, "refs/heads/main", sink)
            .await
            .expect("ensure");

        let patches = compute_unified_patches(
            &ensured,
            &c0.to_hex().to_string(),
            &c1.to_hex().to_string(),
            None,
        )
        .await
        .expect("compute");
        assert_eq!(patches.len(), 1);
        let p = &patches[0];
        assert_eq!(p.path, "logo.png");
        assert!(p.patch.is_empty());
        assert_eq!(p.additions, 0);
        assert_eq!(p.deletions, 0);
    }

    #[test]
    fn looks_binary_detects_null_in_first_8kb() {
        assert!(looks_binary(b"hello\0world"));
        assert!(!looks_binary(b"plain text without nulls"));
        // NUL past 8KB shouldn't flip the bit.
        let mut payload = vec![b'a'; BINARY_SAMPLE_BYTES];
        payload.push(0u8);
        assert!(!looks_binary(&payload));
    }

    #[test]
    fn count_add_del_skips_diff_header_lines() {
        let text = "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n";
        let (a, d) = count_add_del(text);
        assert_eq!(a, 1);
        assert_eq!(d, 1);
    }

    #[test]
    fn count_add_del_handles_pure_addition() {
        let text = "@@ +1,3 @@\n+a\n+b\n+c\n";
        let (a, d) = count_add_del(text);
        assert_eq!(a, 3);
        assert_eq!(d, 0);
    }
}
