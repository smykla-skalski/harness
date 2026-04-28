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
}
