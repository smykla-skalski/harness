//! Bounded file-diff previews for the Reviews Files surface.

use super::{ReviewFilePatch, ReviewFilePreview};

const DEFAULT_PREVIEW_LINE_LIMIT: u32 = 200;

/// Default number of unified-diff lines returned for a preview.
#[must_use]
pub const fn preview_line_limit() -> u32 {
    DEFAULT_PREVIEW_LINE_LIMIT
}

/// Convert a full patch row into a bounded preview row.
#[must_use]
pub fn preview_from_patch(patch: ReviewFilePatch, line_limit: u32) -> ReviewFilePreview {
    let limit = line_limit.clamp(1, preview_line_limit());
    let (body, line_count, has_more) = preview_patch_text(&patch.patch, limit);
    ReviewFilePreview {
        path: patch.path,
        patch: body,
        status: patch.status,
        additions: patch.additions,
        deletions: patch.deletions,
        truncated: patch.truncated,
        etag: patch.etag,
        served_by: patch.served_by,
        fetched_at: patch.fetched_at,
        head_ref_oid: patch.head_ref_oid,
        line_count,
        line_limit: limit,
        has_more,
    }
}

fn preview_patch_text(patch: &str, limit: u32) -> (String, u32, bool) {
    if patch.is_empty() {
        return (String::new(), 0, false);
    }
    let limit = limit as usize;
    let mut lines = patch.split_inclusive('\n');
    let mut out = String::new();
    let mut count = 0_usize;
    while count < limit {
        let Some(line) = lines.next() else {
            break;
        };
        out.push_str(line);
        count += 1;
    }
    let has_more = lines.next().is_some();
    (out, u32::try_from(count).unwrap_or(u32::MAX), has_more)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reviews::files::{ReviewFileChangeType, ReviewFileServedBy};

    fn patch(body: &str) -> ReviewFilePatch {
        ReviewFilePatch {
            path: "src/lib.rs".into(),
            patch: body.into(),
            status: ReviewFileChangeType::Modified,
            additions: 4,
            deletions: 2,
            truncated: false,
            etag: Some(r#""etag""#.into()),
            served_by: ReviewFileServedBy::GithubRest,
            fetched_at: "2026-05-23T12:00:00Z".into(),
            head_ref_oid: "head-a".into(),
        }
    }

    #[test]
    fn preview_keeps_body_under_limit() {
        let preview = preview_from_patch(patch("a\nb\nc\n"), 2);
        assert_eq!(preview.patch, "a\nb\n");
        assert_eq!(preview.line_count, 2);
        assert!(preview.has_more);
        assert_eq!(preview.line_limit, 2);
    }

    #[test]
    fn preview_marks_complete_when_patch_is_shorter() {
        let preview = preview_from_patch(patch("a\nb\n"), 200);
        assert_eq!(preview.patch, "a\nb\n");
        assert_eq!(preview.line_count, 2);
        assert!(!preview.has_more);
        assert_eq!(preview.path, "src/lib.rs");
        assert_eq!(preview.served_by, ReviewFileServedBy::GithubRest);
    }

    #[test]
    fn preview_clamps_zero_limit_to_one() {
        let preview = preview_from_patch(patch("a\nb\n"), 0);
        assert_eq!(preview.patch, "a\n");
        assert_eq!(preview.line_limit, 1);
        assert!(preview.has_more);
    }

    #[test]
    fn preview_marks_exact_limit_without_trailing_newline_complete() {
        let preview = preview_from_patch(patch("a\nb"), 2);
        assert_eq!(preview.patch, "a\nb");
        assert_eq!(preview.line_count, 2);
        assert!(!preview.has_more);
    }
}
