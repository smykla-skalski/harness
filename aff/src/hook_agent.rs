use std::path::{Path, PathBuf};

use clap::ValueEnum;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
#[value(rename_all = "kebab-case")]
pub enum HookAgent {
    Claude,
    Copilot,
    Codex,
    Gemini,
    #[value(name = "vibe")]
    Vibe,
    #[value(name = "opencode")]
    OpenCode,
}

impl HookAgent {
    pub const ALL: [Self; 6] = [
        Self::Claude,
        Self::Codex,
        Self::Gemini,
        Self::Copilot,
        Self::Vibe,
        Self::OpenCode,
    ];

    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Copilot => "copilot",
            Self::Codex => "codex",
            Self::Gemini => "gemini",
            Self::Vibe => "vibe",
            Self::OpenCode => "opencode",
        }
    }

    #[must_use]
    pub fn config_path(self, project_dir: &Path) -> PathBuf {
        match self {
            Self::Claude => project_dir.join(".claude").join("settings.json"),
            Self::Copilot => project_dir
                .join(".github")
                .join("hooks")
                .join("harness.json"),
            Self::Codex => project_dir.join(".codex").join("hooks.json"),
            Self::Gemini => project_dir.join(".gemini").join("settings.json"),
            Self::Vibe => project_dir.join(".vibe").join("hooks.json"),
            Self::OpenCode => project_dir.join(".opencode").join("hooks.json"),
        }
    }

    #[must_use]
    pub fn repo_policy_command(self) -> String {
        format!("aff repo-policy --agent {}", self.name())
    }

    #[must_use]
    pub fn session_start_command(self) -> String {
        format!("aff session-start --agent {}", self.name())
    }
}
