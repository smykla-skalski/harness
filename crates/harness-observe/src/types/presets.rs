use super::IssueCategory;

/// Pre-defined category filter presets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusPreset {
    Harness,
    Skills,
    All,
}

/// Static metadata for a focus preset.
pub struct FocusPresetDef {
    pub name: &'static str,
    pub description: &'static str,
}

static HARNESS_CATEGORIES: &[IssueCategory] = &[
    IssueCategory::BuildError,
    IssueCategory::CliError,
    IssueCategory::WorkflowError,
    IssueCategory::DataIntegrity,
];

static SKILLS_CATEGORIES: &[IssueCategory] = &[
    IssueCategory::SkillBehavior,
    IssueCategory::HookFailure,
    IssueCategory::NamingError,
    IssueCategory::SubagentIssue,
];

pub static FOCUS_PRESETS: &[FocusPresetDef] = &[
    FocusPresetDef {
        name: "harness",
        description: "Build, CLI, workflow, and data integrity issues",
    },
    FocusPresetDef {
        name: "skills",
        description: "Skill behavior, hooks, naming, and subagent issues",
    },
    FocusPresetDef {
        name: "all",
        description: "All categories (no filter)",
    },
];

impl FocusPreset {
    /// Parse from label string.
    #[must_use]
    pub fn from_label(s: &str) -> Option<Self> {
        match s {
            "harness" => Some(Self::Harness),
            "skills" => Some(Self::Skills),
            "all" => Some(Self::All),
            _ => None,
        }
    }

    /// Category filter for this preset. `None` means no filter (all categories).
    #[must_use]
    pub fn categories(self) -> Option<Vec<IssueCategory>> {
        match self {
            Self::Harness => Some(HARNESS_CATEGORIES.to_vec()),
            Self::Skills => Some(SKILLS_CATEGORIES.to_vec()),
            Self::All => None,
        }
    }
}
