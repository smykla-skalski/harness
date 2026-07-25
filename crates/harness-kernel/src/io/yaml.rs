use gray_matter::engine::YAML;
use gray_matter::{Matter, ParsedEntity};
use serde::de::DeserializeOwned;

use crate::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrontmatterDocument<T> {
    pub frontmatter: T,
    pub body: String,
}

/// Parse typed YAML frontmatter from a markdown document.
///
/// # Errors
/// Returns `CliError` if frontmatter is missing, unterminated, or invalid.
pub fn parse_frontmatter<T>(text: &str, label: &str) -> Result<FrontmatterDocument<T>, CliError>
where
    T: DeserializeOwned,
{
    if !text.starts_with("---\n") {
        return Err(CliErrorKind::MissingFrontmatter.into());
    }
    if !text[4..].contains("\n---") {
        return Err(CliErrorKind::UnterminatedFrontmatter.into());
    }

    let matter = Matter::<YAML>::new();
    let parsed: ParsedEntity<T> = matter
        .parse(text)
        .map_err(|error| CliErrorKind::workflow_parse(format!("{label} frontmatter: {error}")))?;
    let frontmatter = parsed.data.ok_or(CliErrorKind::MissingFrontmatter)?;

    Ok(FrontmatterDocument {
        frontmatter,
        body: parsed.content.trim_start_matches('\n').to_string(),
    })
}
