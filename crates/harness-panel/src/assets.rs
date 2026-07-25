//! The single-page app, compiled into the binary.
//!
//! The bundle is built against a sentinel mount point because Vite bakes the
//! asset URLs in at build time while `--base-path` is chosen at start. Only
//! `index.html` mentions the sentinel, so substituting it there is enough to
//! make one build correct under any mount point.

use include_dir::{Dir, include_dir};

use crate::error::PanelError;

static PANEL_ASSETS: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/frontend/dist");

/// The mount point the bundle is built against. Kept in step with `base` in
/// `frontend/vite.config.ts` and the `harness-panel-base` meta tag.
pub const BASE_PATH_SENTINEL: &str = "/__harness_panel_base__";

/// Written by the build script when the web assets were skipped.
const PLACEHOLDER_MARKER: &str = ".harness-panel-placeholder";

const INDEX_HTML: &str = "index.html";

/// The embedded bundle, with `index.html` already pointed at the configured
/// mount point.
#[derive(Debug, Clone)]
pub struct PanelAssets {
    index_html: String,
    placeholder: bool,
}

impl PanelAssets {
    /// Prepare the bundle for a panel mounted at `base_path`.
    ///
    /// # Errors
    /// Returns [`PanelError::Config`] when the embedded bundle has no entry
    /// point, which means the binary was built against an empty `dist`.
    pub fn new(base_path: &str) -> Result<Self, PanelError> {
        let index = PANEL_ASSETS
            .get_file(INDEX_HTML)
            .and_then(|file| file.contents_utf8())
            .ok_or_else(|| {
                PanelError::config(
                    "the embedded panel bundle has no index.html; rebuild with the frontend build \
                     enabled",
                )
            })?;

        Ok(Self {
            index_html: index.replace(BASE_PATH_SENTINEL, base_path),
            placeholder: PANEL_ASSETS.get_file(PLACEHOLDER_MARKER).is_some(),
        })
    }

    /// The entry page, rewritten for this panel's mount point.
    #[must_use]
    pub fn index_html(&self) -> &str {
        &self.index_html
    }

    /// Whether this binary carries the build script's stand-in page instead of
    /// the real app, which `healthz` reports so a placeholder deploy is visible
    /// without loading the page.
    #[must_use]
    pub fn is_placeholder(&self) -> bool {
        self.placeholder
    }

    /// Look up a bundled file by its path below the mount point.
    #[must_use]
    pub fn file(&self, relative_path: &str) -> Option<BundledFile> {
        let path = normalize_asset_path(relative_path)?;
        let file = PANEL_ASSETS.get_file(path)?;
        Some(BundledFile {
            content_type: content_type_for(path),
            // Vite gives every emitted asset a content hash, so a cached copy
            // can never be the wrong version of itself.
            immutable: path.starts_with("assets/"),
            bytes: file.contents(),
        })
    }
}

/// A file to answer a request with.
#[derive(Debug, Clone, Copy)]
pub struct BundledFile {
    pub bytes: &'static [u8],
    pub content_type: &'static str,
    pub immutable: bool,
}

/// Reduce a request path to a bundle lookup, or refuse it.
///
/// `include_dir` resolves by exact key, so a traversal attempt would simply
/// miss. Refusing it here keeps that a property of this function rather than of
/// whichever lookup happens to be underneath.
fn normalize_asset_path(relative_path: &str) -> Option<&str> {
    let trimmed = relative_path.trim_start_matches('/');
    if trimmed.is_empty() || trimmed == INDEX_HTML {
        return None;
    }
    if trimmed
        .split('/')
        .any(|segment| segment == ".." || segment.is_empty())
    {
        return None;
    }
    Some(trimmed)
}

/// `mime_guess` has no opinion about an extensionless file, and answering
/// without a type lets the browser sniff one, so anything unrecognised is
/// served as bytes.
fn content_type_for(path: &str) -> &'static str {
    match path.rsplit_once('.').map(|(_, extension)| extension) {
        Some("js" | "mjs") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("html") => "text/html; charset=utf-8",
        Some("json") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        Some("ico") => "image/x-icon",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::{BASE_PATH_SENTINEL, PanelAssets, content_type_for, normalize_asset_path};

    #[test]
    fn the_entry_page_is_rewritten_for_the_mount_point() {
        let assets = PanelAssets::new("/panel").expect("bundle");

        assert!(assets.index_html().contains("/panel"));
        assert!(
            !assets.index_html().contains(BASE_PATH_SENTINEL),
            "the sentinel must not survive into the served page"
        );
    }

    /// The app reads its mount point back out of this tag to build every API
    /// URL, so the rewrite has to reach it and not just the asset links.
    #[test]
    fn the_rewritten_page_tells_the_app_where_it_is_mounted() {
        let assets = PanelAssets::new("/harness/panel").expect("bundle");

        assert!(
            assets.index_html().contains(r#"content="/harness/panel""#),
            "{}",
            assets.index_html()
        );
    }

    #[test]
    fn a_traversal_attempt_resolves_to_nothing() {
        for path in [
            "../Cargo.toml",
            "assets/../../Cargo.toml",
            "/../etc/passwd",
            "assets//x",
            "",
            "/",
        ] {
            assert!(
                normalize_asset_path(path).is_none()
                    || PanelAssets::new("/panel")
                        .expect("bundle")
                        .file(path)
                        .is_none(),
                "{path} should not resolve"
            );
        }
    }

    /// The entry page is served by the fallback, already rewritten. Serving the
    /// bundled copy as a file would hand out the unrewritten sentinel.
    #[test]
    fn the_entry_page_is_never_served_as_a_bundled_file() {
        let assets = PanelAssets::new("/panel").expect("bundle");

        assert!(assets.file("index.html").is_none());
        assert!(assets.file("/index.html").is_none());
    }

    #[test]
    fn content_types_cover_what_vite_emits() {
        assert_eq!(
            content_type_for("assets/index-abc.js"),
            "text/javascript; charset=utf-8"
        );
        assert_eq!(
            content_type_for("assets/index-abc.css"),
            "text/css; charset=utf-8"
        );
        assert_eq!(content_type_for("favicon"), "application/octet-stream");
    }

    /// Only content-hashed assets may be cached forever; anything else could be
    /// replaced in place by a later build.
    #[test]
    fn only_hashed_assets_are_marked_immutable() {
        let assets = PanelAssets::new("/panel").expect("bundle");
        let hashed = super::PANEL_ASSETS
            .get_dir("assets")
            .and_then(|dir| dir.files().next())
            .map(|file| file.path().to_string_lossy().into_owned())
            .expect("vite always emits at least one hashed asset");

        let bundled = assets.file(&hashed).expect("the hashed asset is bundled");

        assert!(bundled.immutable);
        assert!(!bundled.bytes.is_empty());
    }
}
