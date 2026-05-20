//! Built-in descriptor for the `harness`-managed `OpenRouter` ACP shim.
//!
//! Harness ships and owns the `harness-openrouter-agent` binary; the catalog
//! treats it identically to other ACP agents. The shim speaks ACP over stdio
//! and translates `session/prompt` calls into `OpenRouter` Chat Completions
//! plus the standard ACP tool surface (file IO, terminal lifecycle, permission
//! requests).

use super::{
    AcpAgentDescriptor, AcpSessionConfiguration, AcpSpawnConfiguration, DoctorProbe, tags,
};
use crate::agents::runtime::models;

const OPENROUTER_ID: &str = "openrouter";

#[must_use]
pub fn descriptor() -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: OPENROUTER_ID.to_owned(),
        display_name: "OpenRouter".to_owned(),
        capabilities: vec![
            tags::FS_READ.to_owned(),
            tags::FS_WRITE.to_owned(),
            tags::TERMINAL_SPAWN.to_owned(),
            tags::STREAMING.to_owned(),
            tags::MULTI_TURN.to_owned(),
            tags::REQUIRES_NETWORK.to_owned(),
        ],
        launch_command: "harness-openrouter-agent".to_owned(),
        launch_args: Vec::new(),
        env_passthrough: vec![
            "OPENROUTER_API_URL".to_owned(),
            "OPENROUTER_HTTP_REFERER".to_owned(),
            "OPENROUTER_X_TITLE".to_owned(),
        ],
        spawn_configuration: AcpSpawnConfiguration::None,
        model_catalog: models::catalog_for(OPENROUTER_ID).cloned(),
        install_hint: Some(
            "OpenRouter ACP ships with Harness. Configure the API key via Harness Monitor → Settings → OpenRouter or `harness setup secrets set --kind openrouter`. The daemon delivers the key to the shim via a per-spawn mode-0600 file, never via environment variables."
                .to_owned(),
        ),
        session_configuration: AcpSessionConfiguration::default(),
        doctor_probe: DoctorProbe {
            command: "harness-openrouter-agent".to_owned(),
            args: vec!["--probe".to_owned()],
        },
        prompt_timeout_seconds: Some(600),
        excluded_from_initial_default: true,
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
        assert_eq!(descriptor.launch_command, "harness-openrouter-agent");
        assert!(descriptor.launch_args.is_empty());
        assert_eq!(descriptor.spawn_configuration, AcpSpawnConfiguration::None);
        assert!(descriptor.bundled_with_harness);
    }

    #[test]
    fn doctor_probe_uses_probe_flag() {
        let descriptor = descriptor();
        assert_eq!(descriptor.doctor_probe.command, "harness-openrouter-agent");
        assert_eq!(descriptor.doctor_probe.args, vec!["--probe"]);
    }

    #[test]
    fn env_passthrough_covers_non_secret_openrouter_configuration() {
        let descriptor = descriptor();
        for name in [
            "OPENROUTER_API_URL",
            "OPENROUTER_HTTP_REFERER",
            "OPENROUTER_X_TITLE",
        ] {
            assert!(
                descriptor.env_passthrough.iter().any(|entry| entry == name),
                "env passthrough missing {name}"
            );
        }
    }

    #[test]
    fn env_passthrough_excludes_api_key_to_avoid_env_leakage() {
        let descriptor = descriptor();
        assert!(
            !descriptor
                .env_passthrough
                .iter()
                .any(|entry| entry == "OPENROUTER_API_KEY"),
            "OPENROUTER_API_KEY must not be in env_passthrough — the shim reads its key from --api-key-file written by the daemon, never from the env."
        );
    }

    #[test]
    fn model_catalog_points_at_openrouter_models() {
        let descriptor = descriptor();
        let catalog = descriptor.model_catalog.expect("openrouter model catalog");
        assert_eq!(catalog.runtime, "openrouter");
        assert!(
            catalog
                .models
                .iter()
                .any(|model| model.id == catalog.default)
        );
    }

    #[test]
    fn excluded_from_initial_default_keeps_new_runtime_opt_in() {
        assert!(descriptor().excluded_from_initial_default);
    }
}
