//! Built-in descriptor for the harness-managed Codex ACP adapter.
//!
//! Harness ships and owns the adapter binary, but the underlying ACP server
//! still runs as a supervised stdio child process just like other ACP agents.

use super::{
    AcpAgentDescriptor, AcpSessionConfigOptionBinding, AcpSessionConfiguration,
    AcpSessionEffortTransport, AcpSessionModelTransport, AcpSpawnConfiguration, DoctorProbe, tags,
};
use crate::agents::runtime::models;

const CODEX_ID: &str = "codex";

#[must_use]
pub fn descriptor() -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: CODEX_ID.to_owned(),
        display_name: "Codex".to_owned(),
        capabilities: vec![
            tags::FS_READ.to_owned(),
            tags::FS_WRITE.to_owned(),
            tags::TERMINAL_SPAWN.to_owned(),
            tags::STREAMING.to_owned(),
            tags::MULTI_TURN.to_owned(),
            tags::REQUIRES_NETWORK.to_owned(),
        ],
        launch_command: "harness-codex-acp".to_owned(),
        launch_args: Vec::new(),
        env_passthrough: vec![
            "CODEX_HOME".to_owned(),
            "CODEX_API_KEY".to_owned(),
            "OPENAI_API_KEY".to_owned(),
            "OPENAI_ORGANIZATION".to_owned(),
            "OPENAI_PROJECT".to_owned(),
        ],
        spawn_configuration: AcpSpawnConfiguration::None,
        model_catalog: models::catalog_for(CODEX_ID).cloned(),
        install_hint: Some(
            "Codex ACP ships with Harness. Install or update Harness to restore the bundled `harness-codex-acp` adapter; no separate Codex ACP install is required. Then authenticate via ChatGPT login, CODEX_API_KEY, or OPENAI_API_KEY."
                .to_owned(),
        ),
        session_configuration: AcpSessionConfiguration {
            model: AcpSessionModelTransport::SessionModel,
            effort: AcpSessionEffortTransport::ConfigOption {
                selector: AcpSessionConfigOptionBinding::default(),
            },
            ..Default::default()
        },
        doctor_probe: DoctorProbe {
            command: "harness-codex-acp".to_owned(),
            args: vec!["--probe".to_owned()],
        },
        prompt_timeout_seconds: None,
        excluded_from_initial_default: false,
        bundled_with_harness: true,
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
    fn launch_uses_harness_managed_adapter() {
        let descriptor = descriptor();
        assert_eq!(descriptor.launch_command, "harness-codex-acp");
        assert!(descriptor.launch_args.is_empty());
        assert_eq!(descriptor.spawn_configuration, AcpSpawnConfiguration::None);
        assert!(descriptor.bundled_with_harness);
    }

    #[test]
    fn doctor_probe_uses_hidden_harness_probe() {
        let descriptor = descriptor();
        assert_eq!(descriptor.doctor_probe.command, "harness-codex-acp");
        assert_eq!(descriptor.doctor_probe.args, vec!["--probe"]);
    }

    #[test]
    fn session_configuration_uses_model_and_effort_delivery() {
        let descriptor = descriptor();
        assert_eq!(
            descriptor.session_configuration.model,
            AcpSessionModelTransport::SessionModel
        );
        assert_eq!(
            descriptor.session_configuration.effort,
            AcpSessionEffortTransport::ConfigOption {
                selector: AcpSessionConfigOptionBinding::default(),
            }
        );
    }

    #[test]
    fn env_passthrough_covers_codex_auth_and_state() {
        let descriptor = descriptor();
        for name in [
            "CODEX_HOME",
            "CODEX_API_KEY",
            "OPENAI_API_KEY",
            "OPENAI_ORGANIZATION",
            "OPENAI_PROJECT",
        ] {
            assert!(
                descriptor.env_passthrough.iter().any(|entry| entry == name),
                "env passthrough missing {name}"
            );
        }
    }

    #[test]
    fn model_catalog_points_at_codex_models() {
        let descriptor = descriptor();
        let catalog = descriptor.model_catalog.expect("codex model catalog");
        assert_eq!(catalog.runtime, "codex");
        assert!(
            catalog
                .models
                .iter()
                .any(|model| model.id == catalog.default)
        );
    }
}
