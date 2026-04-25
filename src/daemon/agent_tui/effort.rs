//! Effort-level (reasoning/thinking) injection for the terminal agent launch
//! profile. Split from `model.rs` to stay under the repo source-length limit.

use crate::agents::runtime::models;
use crate::agents::runtime::runtime_for_name;
use crate::errors::{CliError, CliErrorKind};

use super::model::AgentTuiLaunchProfile;

/// Validate the requested effort level against the selected model's allowed
/// values and inject the runtime's effort flag and level into the launch
/// profile argv.
///
/// `model` is the resolved model id (`None` when the request did not specify
/// one, in which case the runtime's default model is used for validation).
/// Runtimes whose CLI does not expose effort accept the effort silently with
/// a warning logged.
///
/// # Errors
/// Returns a workflow parse error when the runtime is unknown, the model id
/// is not in the runtime's catalog, the model does not support effort, or
/// the effort value is not in the model's allowed levels.
pub(super) fn apply_effort_to_profile(
    profile: &mut AgentTuiLaunchProfile,
    model: Option<&str>,
    effort: &str,
    allow_custom: bool,
) -> Result<(), CliError> {
    if !allow_custom {
        let catalog = models::catalog_for(&profile.runtime).ok_or_else(|| {
            CliErrorKind::workflow_parse(format!("unknown runtime '{}'", profile.runtime))
        })?;
        let model_id = model.unwrap_or(catalog.default.as_str());
        let model_entry = catalog
            .models
            .iter()
            .find(|entry| entry.id == model_id)
            .ok_or_else(|| {
                CliErrorKind::workflow_parse(format!(
                    "model '{model_id}' is not valid for runtime '{}'",
                    profile.runtime
                ))
            })?;
        if !model_entry.supports_effort() {
            return Err(CliErrorKind::workflow_parse(format!(
                "model '{model_id}' does not support an effort level"
            ))
            .into());
        }
        if !model_entry
            .effort_values
            .iter()
            .any(|value| value == effort)
        {
            return Err(CliErrorKind::workflow_parse(format!(
                "effort '{effort}' is not valid for model '{model_id}': valid values are {}",
                model_entry.effort_values.join(", ")
            ))
            .into());
        }
    }

    let Some(runtime_adapter) = runtime_for_name(&profile.runtime) else {
        return Err(CliErrorKind::workflow_parse(format!(
            "unsupported terminal agent runtime '{}'",
            profile.runtime
        ))
        .into());
    };

    let Some(flag) = runtime_adapter.effort_flag() else {
        tracing::warn!(
            runtime = %profile.runtime,
            requested_effort = %effort,
            "runtime does not accept an effort flag; ignoring requested effort"
        );
        return Ok(());
    };

    profile.argv.push(flag.to_string());
    profile.argv.push(effort.to_string());
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::agents::runtime::runtime_for_name;

    use super::super::DEFAULT_COLS;
    use super::super::DEFAULT_ROWS;
    use super::super::model::AgentTuiStartRequest;
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
            model: None,
            effort: None,
            allow_custom_model: false,
        }
    }

    #[test]
    fn launch_profile_injects_effort_flag_for_codex() {
        let mut request = base_request("codex");
        request.model = Some("gpt-5.5".into());
        request.effort = Some("medium".into());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "codex".to_string(),
                "--model".to_string(),
                "gpt-5.5".to_string(),
                "--reasoning-effort".to_string(),
                "medium".to_string(),
            ]
        );
    }

    #[test]
    fn launch_profile_drops_effort_for_claude_silently() {
        let mut request = base_request("claude");
        request.model = Some("claude-sonnet-4-6".into());
        request.effort = Some("high".into());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "claude".to_string(),
                "--model".to_string(),
                "claude-sonnet-4-6".to_string(),
            ]
        );
    }

    #[test]
    fn launch_profile_accepts_effort_for_fast_codex_model() {
        let mut request = base_request("codex");
        request.model = Some("gpt-5.3-codex-spark".into());
        request.effort = Some("medium".into());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "codex".to_string(),
                "--model".to_string(),
                "gpt-5.3-codex-spark".to_string(),
                "--reasoning-effort".to_string(),
                "medium".to_string(),
            ]
        );
    }

    #[test]
    fn launch_profile_rejects_unknown_effort_value() {
        let mut request = base_request("codex");
        request.model = Some("gpt-5.5".into());
        request.effort = Some("extreme".into());
        let error = request.launch_profile().expect_err("should reject");
        let message = error.to_string();
        assert!(
            message.contains("extreme"),
            "error should mention requested value: {message}"
        );
    }

    #[test]
    fn launch_profile_uses_runtime_default_when_model_missing() {
        let mut request = base_request("codex");
        request.effort = Some("low".into());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "codex".to_string(),
                "--reasoning-effort".to_string(),
                "low".to_string(),
            ]
        );
    }

    #[test]
    fn empty_effort_string_is_treated_as_none() {
        let mut request = base_request("codex");
        request.model = Some("gpt-5.5".into());
        request.effort = Some(String::new());
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "codex".to_string(),
                "--model".to_string(),
                "gpt-5.5".to_string(),
            ]
        );
    }

    #[test]
    fn custom_model_accepts_arbitrary_effort_level_for_codex() {
        let mut request = base_request("codex");
        request.model = Some("gpt-6-private".into());
        request.effort = Some("maximum".into());
        request.allow_custom_model = true;
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "codex".to_string(),
                "--model".to_string(),
                "gpt-6-private".to_string(),
                "--reasoning-effort".to_string(),
                "maximum".to_string(),
            ]
        );
    }

    #[test]
    fn custom_model_effort_still_dropped_when_runtime_has_no_flag() {
        let mut request = base_request("claude");
        request.model = Some("claude-sonnet-5-0-private".into());
        request.effort = Some("insane".into());
        request.allow_custom_model = true;
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "claude".to_string(),
                "--model".to_string(),
                "claude-sonnet-5-0-private".to_string(),
            ]
        );
    }

    #[test]
    fn allow_custom_model_bypasses_catalog_validation() {
        let mut request = base_request("claude");
        request.model = Some("claude-sonnet-5-0-private".into());
        request.allow_custom_model = true;
        let profile = request.launch_profile().expect("profile");
        assert_eq!(
            profile.argv,
            vec![
                "claude".to_string(),
                "--model".to_string(),
                "claude-sonnet-5-0-private".to_string(),
            ]
        );
    }

    #[test]
    fn claude_effort_env_maps_levels_to_budget_tokens() {
        let claude = runtime_for_name("claude").expect("claude runtime");
        let env: std::collections::BTreeMap<_, _> =
            claude.effort_env("medium").into_iter().collect();
        assert_eq!(
            env.get("HARNESS_CLAUDE_THINKING_LEVEL").map(String::as_str),
            Some("medium")
        );
        assert_eq!(
            env.get("HARNESS_CLAUDE_THINKING_BUDGET_TOKENS")
                .map(String::as_str),
            Some("16384")
        );
    }

    #[test]
    fn claude_effort_env_off_resolves_to_zero_budget() {
        let claude = runtime_for_name("claude").expect("claude runtime");
        let env: std::collections::BTreeMap<_, _> = claude.effort_env("off").into_iter().collect();
        assert_eq!(
            env.get("HARNESS_CLAUDE_THINKING_BUDGET_TOKENS")
                .map(String::as_str),
            Some("0")
        );
    }

    #[test]
    fn gemini_effort_env_maps_levels_to_budget_tokens() {
        let gemini = runtime_for_name("gemini").expect("gemini runtime");
        let env: std::collections::BTreeMap<_, _> = gemini.effort_env("high").into_iter().collect();
        assert_eq!(
            env.get("HARNESS_GEMINI_THINKING_BUDGET_TOKENS")
                .map(String::as_str),
            Some("24576")
        );
    }

    #[test]
    fn codex_effort_env_is_empty_because_flag_based() {
        let codex = runtime_for_name("codex").expect("codex runtime");
        assert!(codex.effort_env("medium").is_empty());
    }
}
