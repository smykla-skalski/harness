//! Kept as its own file, separate from the rest of [`super`]'s wire types:
//! the Swift codegen tool (`examples/policy-codegen.rs`) never lists this
//! file as a source for the reviews-files generated module, because the
//! Monitor app hand-maintains `HarnessCodeLanguage`'s Swift mirror
//! (`HarnessReviewFileLanguage`, see that tool's `TYPE_RENAMES`) instead of
//! generating one. Merging this into the rest of the files module would
//! make the codegen tool start parsing it as a struct/enum source and emit
//! an unwanted new type.

use serde::{Deserialize, Serialize};

/// Compact enum of source languages the diff renderer recognizes. Kept narrow
/// on purpose: tokenizers only exist for these; anything else falls through to
/// the diff-only renderer (no syntax highlighting).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum HarnessCodeLanguage {
    Codeowners,
    Config,
    Dockerfile,
    Diff,
    Feature,
    #[default]
    Generic,
    Go,
    GoModule,
    Gitignore,
    Html,
    Javascript,
    Json,
    Lua,
    Makefile,
    Markdown,
    Powershell,
    Proto,
    Python,
    Rego,
    Rust,
    Ruby,
    Shell,
    Sql,
    Stylesheet,
    Swift,
    Template,
    Terraform,
    Toml,
    Typescript,
    Vue,
    Xml,
    Yaml,
}
