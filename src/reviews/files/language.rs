//! Truth-table language inference from file path/extension.
//!
//! Used by the daemon to annotate `ReviewFile.language_hint`. The
//! Swift Monitor mirrors this same table in `B.1` so cached metadata round-
//! trips have stable values across daemon/client.

use serde::{Deserialize, Serialize};

/// Compact enum of source languages the diff renderer recognizes. Kept narrow
/// on purpose: tokenizers only exist for these; anything else falls through to
/// the diff-only renderer (no syntax highlighting).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
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
            "codeowners" => return HarnessCodeLanguage::Codeowners,
            "dockerfile" | "containerfile" => return HarnessCodeLanguage::Dockerfile,
            "go.mod" | "go.sum" => return HarnessCodeLanguage::GoModule,
            "gemfile" | "gemfile.lock" | "rakefile" => return HarnessCodeLanguage::Ruby,
            "makefile" => return HarnessCodeLanguage::Makefile,
            "package.json" | "package-lock.json" | "tsconfig.json" => {
                return HarnessCodeLanguage::Json;
            }
            "procfile" | "_redirects" | "_headers" | "_common_redirects" => {
                return HarnessCodeLanguage::Config;
            }
            "readme.md" | "changelog.md" => return HarnessCodeLanguage::Markdown,
            _ => {}
        }

        if let Some(ext) = path_extension(name)
            && let Some(language) = language_for_extension(ext)
        {
            return language;
        }

        if name.starts_with("dockerfile.") || name.starts_with("containerfile.") {
            return HarnessCodeLanguage::Dockerfile;
        }
    }

    let Some(ext) = path_extension(&lower) else {
        return HarnessCodeLanguage::Generic;
    };

    language_for_extension(ext).unwrap_or(HarnessCodeLanguage::Generic)
}

fn path_extension(path: &str) -> Option<&str> {
    match path.rsplit('.').next() {
        Some(ext) if !ext.is_empty() && ext != path => Some(ext),
        _ => None,
    }
}

fn language_for_extension(ext: &str) -> Option<HarnessCodeLanguage> {
    match ext {
        "dockerfile" | "containerfile" => Some(HarnessCodeLanguage::Dockerfile),
        "editorconfig" | "gitmodules" | "ini" | "npmrc" | "nvmrc" | "releaserc" | "rspec"
        | "ruby-version" | "service" => Some(HarnessCodeLanguage::Config),
        "gitignore" | "dockerignore" | "eslintignore" | "helmignore" | "helmdocsignore"
        | "npmignore" | "prettierignore" => Some(HarnessCodeLanguage::Gitignore),
        "gotmpl" | "mustache" | "tftpl" | "tmpl" | "tpl" => Some(HarnessCodeLanguage::Template),
        "html" | "htm" => Some(HarnessCodeLanguage::Html),
        "hcl" | "tf" | "tfvars" => Some(HarnessCodeLanguage::Terraform),
        "lua" => Some(HarnessCodeLanguage::Lua),
        "mk" => Some(HarnessCodeLanguage::Makefile),
        "proto" => Some(HarnessCodeLanguage::Proto),
        "ps1" | "psd1" | "psm1" => Some(HarnessCodeLanguage::Powershell),
        "py" => Some(HarnessCodeLanguage::Python),
        "rb" | "gemspec" => Some(HarnessCodeLanguage::Ruby),
        "rego" => Some(HarnessCodeLanguage::Rego),
        "sql" => Some(HarnessCodeLanguage::Sql),
        "scss" | "css" => Some(HarnessCodeLanguage::Stylesheet),
        "swift" => Some(HarnessCodeLanguage::Swift),
        "rs" => Some(HarnessCodeLanguage::Rust),
        "go" => Some(HarnessCodeLanguage::Go),
        "js" | "jsx" | "mjs" | "cjs" => Some(HarnessCodeLanguage::Javascript),
        "ts" | "tsx" | "mts" | "cts" => Some(HarnessCodeLanguage::Typescript),
        "toml" => Some(HarnessCodeLanguage::Toml),
        "xml" | "xsd" | "xsl" | "xslt" => Some(HarnessCodeLanguage::Xml),
        "vue" => Some(HarnessCodeLanguage::Vue),
        "feature" => Some(HarnessCodeLanguage::Feature),
        "sh" | "bash" | "zsh" | "fish" => Some(HarnessCodeLanguage::Shell),
        "json" | "jsonc" => Some(HarnessCodeLanguage::Json),
        "yaml" | "yml" => Some(HarnessCodeLanguage::Yaml),
        "md" | "markdown" | "mdown" => Some(HarnessCodeLanguage::Markdown),
        "patch" | "diff" => Some(HarnessCodeLanguage::Diff),
        _ => None,
    }
}
