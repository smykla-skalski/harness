use std::collections::BTreeMap;
use std::path::PathBuf;

use portable_pty::PtySize;
use serde::{Deserialize, Serialize};

pub use harness_protocol::managed_agents::tui::{
    AgentTuiResizeRequest, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus,
};

use harness_agents::runtime::InitialPromptDelivery;
use harness_kernel::errors::{CliError, CliErrorKind};

use crate::process::AgentTuiProcess;

pub trait AgentTuiSizeExt {
    /// Validate that the PTY has a usable non-zero size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    fn validate(self) -> Result<Self, CliError>
    where
        Self: Sized;

    fn pty_size(self) -> PtySize;
}

impl AgentTuiSizeExt for AgentTuiSize {
    fn validate(self) -> Result<Self, CliError> {
        if self.rows == 0 || self.cols == 0 {
            return Err(CliErrorKind::workflow_parse(
                "terminal agent rows and cols must be greater than zero",
            )
            .into());
        }
        Ok(self)
    }

    fn pty_size(self) -> PtySize {
        PtySize {
            rows: self.rows,
            cols: self.cols,
            pixel_width: 0,
            pixel_height: 0,
        }
    }
}

/// Runtime-specific command profile for launching an interactive agent CLI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentTuiLaunchProfile {
    pub runtime: String,
    pub argv: Vec<String>,
}

impl AgentTuiLaunchProfile {
    /// Resolve the default launch profile for a supported runtime.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime is unknown.
    pub fn for_runtime(runtime: &str) -> Result<Self, CliError> {
        let runtime = runtime.trim();
        let program = match runtime {
            "codex" => "codex",
            "claude" => "claude",
            "gemini" => "gemini",
            "opencode" => "opencode",
            "copilot" => "copilot",
            "vibe" => "vibe",
            _ => {
                return Err(CliErrorKind::workflow_parse(format!(
                    "unsupported terminal agent runtime '{runtime}'"
                ))
                .into());
            }
        };
        Ok(Self {
            runtime: runtime.to_string(),
            argv: vec![program.to_string()],
        })
    }

    /// Build an explicit launch profile from a structured argv override.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime or argv is empty.
    pub fn from_argv(runtime: &str, argv: Vec<String>) -> Result<Self, CliError> {
        let runtime = runtime.trim();
        if runtime.is_empty() {
            return Err(
                CliErrorKind::workflow_parse("terminal agent runtime cannot be empty").into(),
            );
        }
        let Some(program) = argv.first().map(|value| value.trim()) else {
            return Err(CliErrorKind::workflow_parse("terminal agent argv cannot be empty").into());
        };
        if program.is_empty() {
            return Err(
                CliErrorKind::workflow_parse("terminal agent argv[0] cannot be empty").into(),
            );
        }
        Ok(Self {
            runtime: runtime.to_string(),
            argv,
        })
    }
}

/// Fully resolved process spawn request for a managed terminal agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentTuiSpawnSpec {
    pub profile: AgentTuiLaunchProfile,
    pub project_dir: PathBuf,
    pub env: BTreeMap<String, String>,
    pub size: AgentTuiSize,
    /// Optional byte pattern that indicates the runtime is ready for input.
    /// Set from `AgentRuntime::readiness_pattern()`.
    pub readiness_pattern: Option<&'static str>,
    /// How the initial prompt is delivered to this runtime.
    pub prompt_delivery: InitialPromptDelivery,
    /// Join prompt to inject into the CLI argv for `CliPositional`/`CliFlag`
    /// delivery. `None` for `PtySend` runtimes (sent via PTY after readiness).
    pub cli_prompt: Option<String>,
    /// Fall back to screen-text detection when the runtime has no hook system
    /// (Vibe). The reader thread signals ready when visible content appears.
    pub screen_text_fallback: bool,
}

impl AgentTuiSpawnSpec {
    /// Build a spawn spec and validate the runtime profile and PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when the profile or size is invalid.
    pub fn new(
        profile: AgentTuiLaunchProfile,
        project_dir: PathBuf,
        env: BTreeMap<String, String>,
        size: AgentTuiSize,
    ) -> Result<Self, CliError> {
        AgentTuiLaunchProfile::from_argv(&profile.runtime, profile.argv.clone())?;
        Ok(Self {
            profile,
            project_dir,
            env,
            size: size.validate()?,
            readiness_pattern: None,
            prompt_delivery: InitialPromptDelivery::PtySend,
            cli_prompt: None,
            screen_text_fallback: false,
        })
    }
}

/// PTY backend boundary used by the TUI manager.
pub trait AgentTuiBackend {
    /// Spawn an interactive terminal agent inside a PTY.
    ///
    /// # Errors
    /// Returns a workflow I/O error if PTY allocation or process spawning fails.
    fn spawn(&self, spec: AgentTuiSpawnSpec) -> Result<AgentTuiProcess, CliError>;
}

/// Cross-platform PTY backend powered by `portable-pty`.
#[derive(Debug, Clone, Copy, Default)]
pub struct PortablePtyAgentTuiBackend;

impl AgentTuiBackend for PortablePtyAgentTuiBackend {
    fn spawn(&self, spec: AgentTuiSpawnSpec) -> Result<AgentTuiProcess, CliError> {
        AgentTuiProcess::spawn(&spec)
    }
}

pub trait AgentTuiResizeRequestExt {
    /// Resolve and validate the requested PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    fn size(self) -> Result<AgentTuiSize, CliError>;
}

impl AgentTuiResizeRequestExt for AgentTuiResizeRequest {
    fn size(self) -> Result<AgentTuiSize, CliError> {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
        .validate()
    }
}
