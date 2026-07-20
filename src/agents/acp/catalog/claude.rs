//! Built-in descriptor for Claude Code via the official ACP wrapper.
//!
//! The wrapper ships as `@agentclientprotocol/claude-agent-acp` and exposes the
//! `claude-agent-acp` binary. It speaks ACP over stdio by default and proxies
//! auth and local CLI flows through `--cli ...`.

use super::{
    AcpAgentDescriptor, AcpSessionConfigOptionBinding, AcpSessionConfiguration,
    AcpSessionEffortTransport, AcpSessionModelTransport, AcpSpawnConfiguration, DoctorProbe, tags,
};
use crate::agents::runtime::models;

const CLAUDE_ID: &str = "claude";

#[must_use]
pub fn descriptor() -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: CLAUDE_ID.to_owned(),
        display_name: "Claude Code".to_owned(),
        capabilities: vec![
            tags::FS_READ.to_owned(),
            tags::FS_WRITE.to_owned(),
            tags::TERMINAL_SPAWN.to_owned(),
            tags::STREAMING.to_owned(),
            tags::MULTI_TURN.to_owned(),
            tags::REQUIRES_NETWORK.to_owned(),
        ],
        launch_command: "claude-agent-acp".to_owned(),
        launch_args: Vec::new(),
        env_passthrough: vec![
            "ANTHROPIC_API_KEY".to_owned(),
            "ANTHROPIC_AUTH_TOKEN".to_owned(),
            "ANTHROPIC_BASE_URL".to_owned(),
            "ANTHROPIC_CUSTOM_HEADERS".to_owned(),
            "ANTHROPIC_MODEL".to_owned(),
            "CLAUDE_CONFIG_DIR".to_owned(),
            "CLAUDE_CODE_EXECUTABLE".to_owned(),
            "CLAUDE_CODE_REMOTE".to_owned(),
            "CLAUDE_CODE_USE_BEDROCK".to_owned(),
            "CLAUDE_CODE_USE_FOUNDRY".to_owned(),
            "CLAUDE_CODE_USE_VERTEX".to_owned(),
            "CLAUDE_MODEL_CONFIG".to_owned(),
            "AWS_REGION".to_owned(),
            "AWS_PROFILE".to_owned(),
            "AWS_ACCESS_KEY_ID".to_owned(),
            "AWS_SECRET_ACCESS_KEY".to_owned(),
            "AWS_SESSION_TOKEN".to_owned(),
            "GOOGLE_CLOUD_PROJECT".to_owned(),
            "GOOGLE_CLOUD_LOCATION".to_owned(),
            "GOOGLE_APPLICATION_CREDENTIALS".to_owned(),
            "MAX_THINKING_TOKENS".to_owned(),
            "NO_BROWSER".to_owned(),
            "SSH_CONNECTION".to_owned(),
            "SSH_CLIENT".to_owned(),
            "SSH_TTY".to_owned(),
        ],
        spawn_configuration: AcpSpawnConfiguration::None,
        model_catalog: models::catalog_for(CLAUDE_ID).cloned(),
        install_hint: Some(
            "Install the official Claude ACP wrapper (`npm install -g @agentclientprotocol/claude-agent-acp`) and authenticate Claude (`claude login` or ANTHROPIC_API_KEY)."
                .to_owned(),
        ),
        session_configuration: AcpSessionConfiguration {
            model: AcpSessionModelTransport::ConfigOption {
                selector: AcpSessionConfigOptionBinding::default(),
            },
            effort: AcpSessionEffortTransport::ConfigOption {
                selector: AcpSessionConfigOptionBinding::default(),
            },
            ..Default::default()
        },
        doctor_probe: DoctorProbe {
            command: "claude-agent-acp".to_owned(),
            args: vec![
                "--cli".to_owned(),
                "auth".to_owned(),
                "status".to_owned(),
            ],
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: true,
        bundled_with_harness: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_is_stable() {
        let a = descriptor();
        let b = descriptor();
        assert_eq!(a, b);
    }

    #[test]
    fn launch_uses_official_wrapper() {
        let descriptor = descriptor();
        assert_eq!(descriptor.launch_command, "claude-agent-acp");
        assert!(descriptor.launch_args.is_empty());
        assert_eq!(descriptor.spawn_configuration, AcpSpawnConfiguration::None);
    }

    #[test]
    fn doctor_probe_checks_claude_auth_via_wrapper() {
        let descriptor = descriptor();
        assert_eq!(descriptor.doctor_probe.command, "claude-agent-acp");
        assert_eq!(
            descriptor.doctor_probe.args,
            vec!["--cli", "auth", "status"]
        );
    }

    #[test]
    fn session_configuration_uses_acp_native_model_and_effort_delivery() {
        let descriptor = descriptor();
        assert_eq!(
            descriptor.session_configuration.model,
            AcpSessionModelTransport::ConfigOption {
                selector: AcpSessionConfigOptionBinding::default(),
            }
        );
        assert_eq!(
            descriptor.session_configuration.effort,
            AcpSessionEffortTransport::ConfigOption {
                selector: AcpSessionConfigOptionBinding::default(),
            }
        );
    }

    #[test]
    fn env_passthrough_covers_wrapper_configuration_and_auth() {
        let descriptor = descriptor();
        for name in [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_MODEL",
            "CLAUDE_CODE_EXECUTABLE",
            "CLAUDE_MODEL_CONFIG",
            "MAX_THINKING_TOKENS",
        ] {
            assert!(
                descriptor.env_passthrough.iter().any(|entry| entry == name),
                "env passthrough missing {name}"
            );
        }
    }

    #[test]
    fn model_catalog_points_at_claude_models() {
        let descriptor = descriptor();
        let catalog = descriptor.model_catalog.expect("claude model catalog");
        assert_eq!(catalog.runtime, "claude");
        assert!(
            catalog
                .models
                .iter()
                .any(|model| model.id == catalog.default)
        );
    }

    #[test]
    fn descriptor_is_not_initial_default_candidate() {
        assert!(descriptor().excluded_from_initial_default);
    }
}
