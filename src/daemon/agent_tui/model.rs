use std::collections::BTreeMap;
use std::path::PathBuf;

use portable_pty::PtySize;
use serde::{Deserialize, Serialize};

#[cfg(feature = "daemon-runtime")]
pub use harness_protocol::managed_agents::tui::{AgentTuiListResponse, AgentTuiStartRequest};
pub use harness_protocol::managed_agents::tui::{
    AgentTuiResizeRequest, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus,
};

use crate::agents::runtime::InitialPromptDelivery;
#[cfg(feature = "daemon-runtime")]
use crate::agents::runtime::{models, runtime_for_name};
use crate::errors::{CliError, CliErrorKind};

#[cfg(feature = "daemon-runtime")]
use super::effort::apply_effort_to_profile;
use super::process::AgentTuiProcess;
#[cfg(all(test, feature = "daemon-runtime"))]
use super::{DEFAULT_COLS, DEFAULT_ROWS};

pub(crate) trait AgentTuiSizeExt {
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

#[cfg(feature = "daemon-runtime")]
pub(super) const fn session_disconnect_reason(status: AgentTuiStatus) -> Option<&'static str> {
    match status {
        AgentTuiStatus::Exited => Some("managed terminal agent exited"),
        AgentTuiStatus::Failed => Some("managed terminal agent failed"),
        AgentTuiStatus::Stopped => Some("managed terminal agent stopped"),
        AgentTuiStatus::Starting | AgentTuiStatus::Running => None,
    }
}

#[cfg(feature = "daemon-runtime")]
pub(crate) trait AgentTuiStartRequestExt {
    /// Resolve and validate the runtime profile used for PTY spawning.
    ///
    /// # Errors
    /// Returns a workflow parse error when the runtime or argv is invalid, or
    /// when the requested model is not in the runtime's catalog.
    fn launch_profile(&self) -> Result<AgentTuiLaunchProfile, CliError>;

    /// Resolve and validate the requested PTY size.
    ///
    /// # Errors
    /// Returns a workflow parse error when either dimension is zero.
    fn size(&self) -> Result<AgentTuiSize, CliError>;
}

#[cfg(feature = "daemon-runtime")]
impl AgentTuiStartRequestExt for AgentTuiStartRequest {
    fn launch_profile(&self) -> Result<AgentTuiLaunchProfile, CliError> {
        let default_profile = AgentTuiLaunchProfile::for_runtime(&self.runtime)?;
        let mut profile = if self.argv.is_empty() {
            default_profile
        } else {
            AgentTuiLaunchProfile::from_argv(&default_profile.runtime, self.argv.clone())?
        };
        let model = self.model.as_deref().filter(|value| !value.is_empty());
        if let Some(model) = model {
            apply_model_to_profile(&mut profile, model, self.allow_custom_model)?;
        }
        if let Some(effort) = self.effort.as_deref().filter(|value| !value.is_empty()) {
            apply_effort_to_profile(&mut profile, model, effort, self.allow_custom_model)?;
        }
        Ok(profile)
    }

    fn size(&self) -> Result<AgentTuiSize, CliError> {
        AgentTuiSize {
            rows: self.rows,
            cols: self.cols,
        }
        .validate()
    }
}

/// Validate the requested model against the runtime catalog and inject the
/// runtime's `--model` flag and id into the launch profile argv.
///
/// Runtimes that do not accept a `--model` flag are accepted silently with a
/// warning logged. Unknown runtimes or models are rejected with a workflow
/// parse error.
#[cfg(feature = "daemon-runtime")]
fn apply_model_to_profile(
    profile: &mut AgentTuiLaunchProfile,
    model: &str,
    allow_custom: bool,
) -> Result<(), CliError> {
    if !allow_custom {
        models::validate_model(&profile.runtime, model).map_err(|valid_ids| {
            let detail = if valid_ids.is_empty() {
                format!("unknown runtime '{}'", profile.runtime)
            } else {
                format!("valid models: {}", valid_ids.join(", "))
            };
            CliErrorKind::workflow_parse(format!(
                "model '{model}' is not valid for runtime '{}': {detail}",
                profile.runtime
            ))
        })?;
    }

    let Some(runtime_adapter) = runtime_for_name(&profile.runtime) else {
        return Err(CliErrorKind::workflow_parse(format!(
            "unsupported terminal agent runtime '{}'",
            profile.runtime
        ))
        .into());
    };

    let Some(flag) = runtime_adapter.model_flag() else {
        tracing::warn!(
            runtime = %profile.runtime,
            requested_model = %model,
            "runtime does not accept a model flag; ignoring requested model"
        );
        return Ok(());
    };

    profile.argv.push(flag.to_string());
    profile.argv.push(model.to_string());
    Ok(())
}

pub(crate) trait AgentTuiResizeRequestExt {
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

#[cfg(all(test, feature = "daemon-runtime"))]
mod model_selection_tests {
    use super::*;
    use crate::session::types::SessionRole;

    fn base_request(runtime: &str) -> AgentTuiStartRequest {
        AgentTuiStartRequest {
            runtime: runtime.to_string(),
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: vec![],
            name: None,
            prompt: None,
            project_dir: None,
            argv: Vec::new(),
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
            persona: None,
            task_id: None,
            board_item_id: None,
            workflow_execution_id: None,
            model: None,
            effort: None,
            allow_custom_model: false,
        }
    }

    #[test]
    fn launch_profile_injects_model_flag_when_model_is_valid() {
        let mut request = base_request("claude");
        request.model = Some("claude-haiku-4-5".into());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "claude".to_string(),
                "--model".to_string(),
                "claude-haiku-4-5".to_string(),
            ]
        );
    }

    #[test]
    fn launch_profile_rejects_unknown_model_for_runtime() {
        let mut request = base_request("claude");
        request.model = Some("418cf829-6691-5fc0-92b1-8e5013efa2cb-model".into());
        let error = request.launch_profile().expect_err("should reject");
        let message = error.to_string();
        assert!(
            message.contains("418cf829-6691-5fc0-92b1-8e5013efa2cb-model"),
            "error should mention requested model: {message}"
        );
        assert!(
            message.contains("claude-sonnet-4-6"),
            "error should list valid claude models: {message}"
        );
    }

    #[test]
    fn launch_profile_skips_model_injection_when_not_specified() {
        let request = base_request("codex");
        let profile = request.launch_profile().expect("profile");
        assert_eq!(profile.argv, vec!["codex".to_string()]);
    }

    #[test]
    fn launch_profile_appends_model_to_argv_override() {
        let mut request = base_request("gemini");
        request.argv = vec!["gemini".into(), "--debug".into()];
        request.model = Some("gemini-2.5-flash".into());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "gemini".to_string(),
                "--debug".to_string(),
                "--model".to_string(),
                "gemini-2.5-flash".to_string(),
            ]
        );
    }

    #[test]
    fn empty_model_string_is_treated_as_none() {
        let mut request = base_request("vibe");
        request.model = Some(String::new());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(profile.argv, vec!["vibe".to_string()]);
    }
}
