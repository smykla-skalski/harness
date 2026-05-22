//! Unified-diff parser for the local-clone diff strategy.
//!
//! Given the raw output of
//! `git --git-dir=<clone> diff --no-color --unified=3 <base>..<head>`,
//! splits the multi-file diff into per-file blocks and produces
//! `ReviewFilePatch` rows with full content (never truncated)
//! and `served_by = LocalClone`.
//!
//! Hand-rolled (no `unidiff` crate) to keep our supply chain narrow and
//! the parser predictable - we only need a small subset of unified diff
//! shape: `diff --git`, `rename` headers, `--- / +++` markers, binary
//! markers, and hunk bodies.

use super::{
    ReviewFileChangeType, ReviewFilePatch, ReviewFileServedBy,
};

/// Parse `git diff` output and return per-file patches.
///
/// The output is assumed to come from `--no-color` so no ANSI handling is
/// needed. Binary files are surfaced with `patch == ""` and additions /
/// deletions == 0.
#[must_use]
pub fn parse_git_diff(raw: &str) -> Vec<ReviewFilePatch> {
    let mut out = Vec::new();
    let mut current: Option<ReviewFilePatch> = None;
    let mut current_body: String = String::new();
    let mut in_hunk = false;

    for line in raw.split_inclusive('\n') {
        if let Some(header) = line.strip_prefix("diff --git ") {
            // Flush the previous file into the output list.
            if let Some(mut patch) = current.take() {
                patch.patch = std::mem::take(&mut current_body);
                out.push(patch);
            }
            in_hunk = false;
            let trimmed = header.trim_end_matches('\n');
            let path = parse_diff_git_header(trimmed).unwrap_or_else(|| "<unknown>".to_string());
            current = Some(ReviewFilePatch {
                path,
                patch: String::new(),
                status: ReviewFileChangeType::Modified,
                additions: 0,
                deletions: 0,
                truncated: false,
                etag: None,
                served_by: ReviewFileServedBy::LocalClone,
                fetched_at: String::new(),
                head_ref_oid: String::new(),
            });
            // Keep the diff header in the patch body so consumers can show
            // the full unified diff including the `diff --git` line.
            current_body.push_str(line);
            continue;
        }

        let Some(patch) = current.as_mut() else {
            continue;
        };

        if line.starts_with("Binary files ") {
            patch.status = ReviewFileChangeType::Modified;
            current_body.push_str(line);
            continue;
        }
        if line.starts_with("new file mode ") {
            patch.status = ReviewFileChangeType::Added;
            current_body.push_str(line);
            continue;
        }
        if line.starts_with("deleted file mode ") {
            patch.status = ReviewFileChangeType::Deleted;
            current_body.push_str(line);
            continue;
        }
        if line.starts_with("rename from ") || line.starts_with("rename to ") {
            patch.status = ReviewFileChangeType::Renamed;
            current_body.push_str(line);
            continue;
        }
        if line.starts_with("copy from ") || line.starts_with("copy to ") {
            patch.status = ReviewFileChangeType::Copied;
            current_body.push_str(line);
            continue;
        }
        if line.starts_with("@@ ") {
            in_hunk = true;
            current_body.push_str(line);
            continue;
        }
        if in_hunk {
            if let Some(first) = line.chars().next() {
                match first {
                    '+' if !line.starts_with("+++") => patch.additions += 1,
                    '-' if !line.starts_with("---") => patch.deletions += 1,
                    _ => {}
                }
            }
        }
        current_body.push_str(line);
    }
    if let Some(mut patch) = current.take() {
        patch.patch = current_body;
        out.push(patch);
    }
    out
}

/// Given a `diff --git a/<path> b/<path>` header line (without the leading
/// `diff --git `), recover the path. Falls back to the `b/<path>` side for
/// renames; if neither side is present, returns None.
#[must_use]
pub fn parse_diff_git_header(line: &str) -> Option<String> {
    // Format: `a/<path> b/<path>` (paths may be quoted with C-escapes for
    // non-printable filenames; we don't try to unescape - the consumer only
    // needs the readable form).
    let mut parts = line.splitn(2, ' ');
    let _ = parts.next()?; // a/<path>
    let b = parts.next()?;
    let b = b.trim();
    b.strip_prefix("b/").map(String::from)
}

/// Inspect a single line of `git diff --numstat` output to detect binary
/// markers (`-\t-\t<path>`). Returns true when the line indicates a binary
/// file.
#[must_use]
pub fn numstat_is_binary(line: &str) -> bool {
    let parts: Vec<&str> = line.splitn(3, '\t').collect();
    if parts.len() < 2 {
        return false;
    }
    parts[0] == "-" && parts[1] == "-"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_diff_git_header_extracts_path() {
        let line = "a/src/lib.rs b/src/lib.rs";
        assert_eq!(parse_diff_git_header(line), Some("src/lib.rs".into()));
    }

    #[test]
    fn parse_diff_git_header_handles_rename() {
        let line = "a/old/path.rs b/new/path.rs";
        assert_eq!(parse_diff_git_header(line), Some("new/path.rs".into()));
    }

    #[test]
    fn parse_diff_git_header_returns_none_on_garbage() {
        assert_eq!(parse_diff_git_header(""), None);
        assert_eq!(parse_diff_git_header("no slash"), None);
    }

    #[test]
    fn parse_simple_two_file_diff() {
        let raw = "diff --git a/src/a.rs b/src/a.rs\n\
                   index 1111111..2222222 100644\n\
                   --- a/src/a.rs\n\
                   +++ b/src/a.rs\n\
                   @@ -1,3 +1,3 @@\n\
                    line one\n\
                   -line two\n\
                   +line two changed\n\
                    line three\n\
                   diff --git a/src/b.rs b/src/b.rs\n\
                   new file mode 100644\n\
                   --- /dev/null\n\
                   +++ b/src/b.rs\n\
                   @@ -0,0 +1,2 @@\n\
                   +alpha\n\
                   +beta\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 2);
        assert_eq!(patches[0].path, "src/a.rs");
        assert_eq!(patches[0].status, ReviewFileChangeType::Modified);
        assert_eq!(patches[0].additions, 1);
        assert_eq!(patches[0].deletions, 1);
        assert_eq!(patches[1].path, "src/b.rs");
        assert_eq!(patches[1].status, ReviewFileChangeType::Added);
        assert_eq!(patches[1].additions, 2);
        assert_eq!(patches[1].deletions, 0);
        assert_eq!(
            patches[0].served_by,
            ReviewFileServedBy::LocalClone
        );
        // Body retained for consumers to render.
        assert!(patches[0].patch.contains("@@"));
    }

    #[test]
    fn parse_renamed_file_diff() {
        let raw = "diff --git a/old/path.rs b/new/path.rs\n\
                   similarity index 100%\n\
                   rename from old/path.rs\n\
                   rename to new/path.rs\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].path, "new/path.rs");
        assert_eq!(patches[0].status, ReviewFileChangeType::Renamed);
        assert_eq!(patches[0].additions, 0);
        assert_eq!(patches[0].deletions, 0);
    }

    #[test]
    fn parse_deleted_file_diff() {
        let raw = "diff --git a/old.rs b/old.rs\n\
                   deleted file mode 100644\n\
                   --- a/old.rs\n\
                   +++ /dev/null\n\
                   @@ -1,2 +0,0 @@\n\
                   -foo\n\
                   -bar\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].path, "old.rs");
        assert_eq!(patches[0].status, ReviewFileChangeType::Deleted);
        assert_eq!(patches[0].additions, 0);
        assert_eq!(patches[0].deletions, 2);
    }

    #[test]
    fn parse_binary_file_diff() {
        let raw = "diff --git a/logo.png b/logo.png\n\
                   index 1111..2222 100644\n\
                   Binary files a/logo.png and b/logo.png differ\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].path, "logo.png");
        assert_eq!(patches[0].additions, 0);
        assert_eq!(patches[0].deletions, 0);
        // Body retained so consumers can decide to surface a binary placeholder.
        assert!(patches[0].patch.contains("Binary files"));
    }

    #[test]
    fn parse_no_newline_at_eof_marker() {
        let raw = "diff --git a/short.txt b/short.txt\n\
                   --- a/short.txt\n\
                   +++ b/short.txt\n\
                   @@ -1 +1 @@\n\
                   -last line\n\
                   \\ No newline at end of file\n\
                   +last line changed\n\
                   \\ No newline at end of file\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].additions, 1);
        assert_eq!(patches[0].deletions, 1);
        // The "\ No newline" marker isn't counted as add/del.
        assert!(patches[0].patch.contains("No newline"));
    }

    #[test]
    fn parse_empty_diff_returns_no_patches() {
        let patches = parse_git_diff("");
        assert!(patches.is_empty());
    }

    #[test]
    fn served_by_is_local_clone_for_all_outputs() {
        let raw = "diff --git a/x.rs b/x.rs\n@@ -1 +1 @@\n-a\n+b\n";
        for p in parse_git_diff(raw) {
            assert_eq!(p.served_by, ReviewFileServedBy::LocalClone);
        }
    }

    #[test]
    fn numstat_recognises_binary_marker() {
        assert!(numstat_is_binary("-\t-\tlogo.png"));
        assert!(!numstat_is_binary("12\t5\tsrc/lib.rs"));
        assert!(!numstat_is_binary(""));
        assert!(!numstat_is_binary("\tjunk"));
    }

    #[test]
    fn parse_copy_diff_sets_copied_status() {
        let raw = "diff --git a/old.rs b/new.rs\n\
                   similarity index 100%\n\
                   copy from old.rs\n\
                   copy to new.rs\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 1);
        assert_eq!(patches[0].status, ReviewFileChangeType::Copied);
    }

    #[test]
    fn parse_three_file_diff_preserves_order() {
        let raw = "diff --git a/a.rs b/a.rs\n\
                   @@ -1 +1 @@\n\
                   -x\n\
                   +y\n\
                   diff --git a/b.rs b/b.rs\n\
                   @@ -1 +1 @@\n\
                   -x\n\
                   +y\n\
                   diff --git a/c.rs b/c.rs\n\
                   @@ -1 +1 @@\n\
                   -x\n\
                   +y\n";
        let patches = parse_git_diff(raw);
        assert_eq!(patches.len(), 3);
        assert_eq!(patches[0].path, "a.rs");
        assert_eq!(patches[1].path, "b.rs");
        assert_eq!(patches[2].path, "c.rs");
    }
}
