use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::item_fields::ExternalRefProvider;
use super::runtime_config::normalize_repository_slug;

const PROJECT_ID_PREFIX: &str = "project-";
const PROJECT_ID_BODY_LEN: usize = 32;

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
    Todoist,
    Manual,
}

impl TaskBoardProjectSource {
    /// Canonical form of a slug for this source, or `None` when the value
    /// cannot name a project.
    #[must_use]
    pub fn normalize_slug(self, raw: &str) -> Option<String> {
        match self {
            Self::GitHub => normalize_repository_slug(Some(raw)),
            // The provider owns these, so case is significant and the only
            // reshaping that is safe is trimming transport whitespace.
            Self::Todoist | Self::Manual => {
                let trimmed = raw.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_owned())
            }
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "github" => Some(Self::GitHub),
            "todoist" => Some(Self::Todoist),
            "manual" => Some(Self::Manual),
            _ => None,
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::GitHub => "github",
            Self::Todoist => "todoist",
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
    // `project_id` is the provider's own project value: a repository slug on
    // some rows, a Todoist project id on others. GitHub imports name their
    // repository only in `execution_repository`, which is why it is the
    // fallback rather than the first choice.
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
        return ItemProjectAttribution::Unattributed;
    };
    if let Some(slug) = TaskBoardProjectSource::GitHub.normalize_slug(raw) {
        return ItemProjectAttribution::Register(TaskBoardProjectSource::GitHub, slug);
    }
    let source = if item.imported_from_provider == Some(ExternalRefProvider::Todoist) {
        TaskBoardProjectSource::Todoist
    } else {
        TaskBoardProjectSource::Manual
    };
    source.normalize_slug(raw).map_or(
        ItemProjectAttribution::Unattributed,
        |slug| ItemProjectAttribution::Register(source, slug),
    )
}

#[cfg(test)]
mod tests;
