//! Truth-table language inference from file path/extension.
//!
//! Used by the daemon to annotate `DependencyUpdateFile.language_hint`. The
//! Swift Monitor mirrors this same table in `B.1` so cached metadata round-
//! trips have stable values across daemon/client.

use serde::{Deserialize, Serialize};

/// Compact enum of source languages the diff renderer recognizes. Kept narrow
/// on purpose: tokenizers only exist for these; anything else falls through to
/// the diff-only renderer (no syntax highlighting).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum HarnessCodeLanguage {
    Diff,
    #[default]
    Generic,
    Json,
    Markdown,
    Rust,
    Shell,
    Swift,
    Yaml,
}

/// Infer a `HarnessCodeLanguage` from a repo-relative path.
///
/// The function is intentionally cheap (no regex, no allocations beyond the
/// case-insensitive comparison) so it can run inside the GraphQL response
/// ingest loop without measurable cost.
#[must_use]
pub fn infer_language(path: &str) -> HarnessCodeLanguage {
    let lower = path.to_ascii_lowercase();

    // Filename-based matches first (Dockerfile, Makefile etc.).
    if let Some(name) = lower.rsplit('/').next() {
        match name {
            "dockerfile" | "containerfile" => return HarnessCodeLanguage::Generic,
            "makefile" => return HarnessCodeLanguage::Generic,
            "package.json" | "package-lock.json" | "tsconfig.json" => {
                return HarnessCodeLanguage::Json;
            }
            "readme.md" | "changelog.md" => return HarnessCodeLanguage::Markdown,
            _ => {}
        }
    }

    let ext = match lower.rsplit('.').next() {
        Some(ext) if !ext.is_empty() && ext != lower => ext,
        _ => return HarnessCodeLanguage::Generic,
    };

    match ext {
        "swift" => HarnessCodeLanguage::Swift,
        "rs" => HarnessCodeLanguage::Rust,
        "sh" | "bash" | "zsh" | "fish" => HarnessCodeLanguage::Shell,
        "json" | "jsonc" => HarnessCodeLanguage::Json,
        "yaml" | "yml" => HarnessCodeLanguage::Yaml,
        "md" | "markdown" | "mdown" => HarnessCodeLanguage::Markdown,
        "patch" | "diff" => HarnessCodeLanguage::Diff,
        _ => HarnessCodeLanguage::Generic,
    }
}
