use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::item_fields::{ExternalRef, ExternalRefProvider};
use super::project_color::TaskBoardProjectColor;
use super::project_shape::TaskBoardProjectShape;
use super::runtime_config::normalize_repository_slug;

const PROJECT_ID_PREFIX: &str = "project-";
const PROJECT_ID_BODY_LEN: usize = 32;
/// Mirrors the column's CHECK, which measures bytes rather than characters.
/// Normalizing has to agree with it: `ensure_project_in_tx` inserts with
/// `ON CONFLICT DO NOTHING`, which swallows a duplicate but not a CHECK
/// violation, so an oversize slug reaching it fails the write and reads as a
/// store error for what is really a caller mistake. The v51 backfill is not
/// affected - its `INSERT OR IGNORE` skips the row and leaves the item
/// unattributed.
const PROJECT_SLUG_MAX_BYTES: usize = 256;

/// Where a project's identity comes from. The source scopes the slug, because
/// two providers may hand out the same slug for unrelated projects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardProjectSource {
    // `snake_case` would split this into `git_hub`, which is neither what
    // `as_str` stores nor what the column's CHECK constraint accepts.
    #[serde(rename = "github")]
    GitHub,
    Manual,
}

impl TaskBoardProjectSource {
    /// Canonical form of a slug for this source, or `None` when the value
    /// cannot name a project.
    #[must_use]
    pub fn normalize_slug(self, raw: &str) -> Option<String> {
        let normalized = match self {
            Self::GitHub => normalize_repository_slug(Some(raw)),
            // A hand-entered name is whatever the user typed, so case is
            // significant and the only reshaping that is safe is trimming
            // transport whitespace.
            Self::Manual => {
                let trimmed = raw.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_owned())
            }
        };
        normalized.filter(|slug| slug.len() <= PROJECT_SLUG_MAX_BYTES)
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "github" => Some(Self::GitHub),
            "manual" => Some(Self::Manual),
            _ => None,
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::GitHub => "github",
            Self::Manual => "manual",
        }
    }
}

/// A named source of board work. `project_id` is assigned once and never
/// changes, so renaming a project leaves every item still attached to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardProject {
    pub project_id: String,
    pub source: TaskBoardProjectSource,
    pub slug: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    /// Not optional even though the column is. A project with no color is not
    /// a state any caller should have to render, so the store resolves one on
    /// the way out rather than passing the gap along.
    pub color: TaskBoardProjectColor,
    /// The other half of the mark, resolved the same way. A board the palette
    /// still covers stores nothing and every project reads back as the default,
    /// so a client renders one shape without knowing why.
    pub shape: TaskBoardProjectShape,
    pub created_at: String,
    pub updated_at: String,
}

impl TaskBoardProject {
    #[must_use]
    pub fn generate_id() -> String {
        format!("{PROJECT_ID_PREFIX}{}", Uuid::new_v4().simple())
    }

    /// What a person should see. Never the opaque identifier.
    #[must_use]
    pub fn label(&self) -> &str {
        self.display_name
            .as_deref()
            .filter(|name| !name.trim().is_empty())
            .unwrap_or(&self.slug)
    }
}

/// Whether a value is an assigned project identifier. Display paths lean on
/// this to avoid ever showing a raw identifier when a project row is missing.
///
/// Lowercase only, matching both producers (`generate_id` and the v51 backfill)
/// and the column's CHECK constraint. Accepting a spelling the database rejects
/// would let a write path call a value assigned that can never be stored, and
/// accepting one the database allows but this rejects is worse still: the row
/// persists and every later read silently treats the item as unattributed.
#[must_use]
pub fn is_project_id(value: &str) -> bool {
    let Some(body) = value.strip_prefix(PROJECT_ID_PREFIX) else {
        return false;
    };
    body.len() == PROJECT_ID_BODY_LEN
        && body.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// What a write path must do about an item's project attribution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ItemProjectAttribution {
    /// The item already points at a registered project.
    Assigned,
    /// The item names a project that may still need registering.
    Register(TaskBoardProjectSource, String),
    /// Nothing on the item names a project.
    Unattributed,
}

/// Read an item's origin. This is the runtime half of the v51 backfill and
/// reads the same two columns in the same order, so an item created now and
/// one migrated then land on the same project.
#[must_use]
pub fn item_attribution(item: &super::types::TaskBoardItem) -> ItemProjectAttribution {
    if item
        .source_project_id
        .as_deref()
        .is_some_and(is_project_id)
    {
        return ItemProjectAttribution::Assigned;
    }
    // `project_id` is the provider's own project value, a repository slug on
    // rows that carry one. GitHub imports name their repository only in
    // `execution_repository`, which is why it is the fallback rather than the
    // first choice.
    let raw = item
        .project_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            item.execution_repository
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
        });
    let Some(raw) = raw else {
        return external_ref_attribution(item);
    };
    if let Some(slug) = TaskBoardProjectSource::GitHub.normalize_slug(raw) {
        return ItemProjectAttribution::Register(TaskBoardProjectSource::GitHub, slug);
    }
    let source = TaskBoardProjectSource::Manual;
    source.normalize_slug(raw).map_or(
        ItemProjectAttribution::Unattributed,
        |slug| ItemProjectAttribution::Register(source, slug),
    )
}

/// The repository named by the first GitHub ref that carries one.
///
/// A review requested on a repository nothing else tracks arrives with both
/// columns empty and its repository only inside `owner/repo#number` or the pull
/// request URL. The card already reads its label from that ref, so attribution
/// has to read it too or the label names a project the item does not have.
fn external_ref_attribution(item: &super::types::TaskBoardItem) -> ItemProjectAttribution {
    item.external_refs
        .iter()
        .filter(|reference| reference.provider == ExternalRefProvider::GitHub)
        .find_map(external_ref_slug)
        .map_or(ItemProjectAttribution::Unattributed, |slug| {
            ItemProjectAttribution::Register(TaskBoardProjectSource::GitHub, slug)
        })
}

fn external_ref_slug(reference: &ExternalRef) -> Option<String> {
    let raw = reference
        .url
        .as_deref()
        .and_then(slug_from_github_url)
        .or_else(|| slug_from_reference_id(&reference.external_id))?;
    TaskBoardProjectSource::GitHub.normalize_slug(&raw)
}

fn slug_from_github_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let rest = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))?;
    let (host, path) = rest.split_once('/')?;
    let host = host.to_ascii_lowercase();
    if host != "github.com" && host != "www.github.com" {
        return None;
    }
    slug_from_segments(path)
}

fn slug_from_reference_id(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if let Some(slug) = slug_from_github_url(trimmed) {
        return Some(slug);
    }
    let without_number = trimmed.split_once('#').map_or(trimmed, |(head, _)| head);
    slug_from_segments(without_number)
}

fn slug_from_segments(path: &str) -> Option<String> {
    let mut segments = path.split('/').filter(|segment| !segment.is_empty());
    let owner = segments.next()?;
    let repository = segments.next()?;
    Some(format!("{owner}/{repository}"))
}

#[cfg(test)]
mod tests;
