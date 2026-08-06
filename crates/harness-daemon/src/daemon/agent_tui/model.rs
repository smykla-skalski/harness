pub use harness_protocol::managed_agents::tui::{AgentTuiListResponse, AgentTuiStartRequest};

use crate::agents::runtime::{models, runtime_for_name};
use harness_daemon_managed_agents::{
    AgentTuiLaunchProfile, AgentTuiSize, AgentTuiSizeExt, AgentTuiStatus,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::effort::apply_effort_to_profile;
#[cfg(test)]
use super::{DEFAULT_COLS, DEFAULT_ROWS};

pub(super) const fn session_disconnect_reason(status: AgentTuiStatus) -> Option<&'static str> {
    match status {
        AgentTuiStatus::Exited => Some("managed terminal agent exited"),
        AgentTuiStatus::Failed => Some("managed terminal agent failed"),
        AgentTuiStatus::Stopped => Some("managed terminal agent stopped"),
        AgentTuiStatus::Starting | AgentTuiStatus::Running => None,
    }
}

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

#[cfg(test)]
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
