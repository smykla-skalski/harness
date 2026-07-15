use std::path::{Path, PathBuf};

use crate::hooks::adapters::HookAgent;
use crate::workspace::project_context_dir;

#[path = "../../../../src/agents/runtime/signal/mod.rs"]
pub mod signal;

pub trait AgentRuntime: Send + Sync {
    fn name(&self) -> &'static str;

    fn signal_dir(&self, project_dir: &Path, session_id: &str) -> PathBuf {
        project_context_dir(project_dir)
            .join("agents/signals")
            .join(self.name())
            .join(session_id)
    }
}

struct HookRuntime(&'static str);

impl AgentRuntime for HookRuntime {
    fn name(&self) -> &'static str {
        self.0
    }
}

static CLAUDE: HookRuntime = HookRuntime("claude");
static CODEX: HookRuntime = HookRuntime("codex");
static GEMINI: HookRuntime = HookRuntime("gemini");
static COPILOT: HookRuntime = HookRuntime("copilot");
static VIBE: HookRuntime = HookRuntime("vibe");
static OPENCODE: HookRuntime = HookRuntime("opencode");

#[must_use]
pub fn runtime_for(agent: HookAgent) -> &'static dyn AgentRuntime {
    match agent {
        HookAgent::Claude => &CLAUDE,
        HookAgent::Codex => &CODEX,
        HookAgent::Gemini => &GEMINI,
        HookAgent::Copilot => &COPILOT,
        HookAgent::Vibe => &VIBE,
        HookAgent::OpenCode => &OPENCODE,
    }
}
