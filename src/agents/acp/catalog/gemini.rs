//! Built-in descriptor for Gemini CLI speaking ACP.
//!
//! Gemini CLI documents ACP over stdio behind `gemini --acp`. The descriptor is
//! deliberately catalog-only: Gemini exercises the same supervision,
//! permission, and filesystem policy paths as every other ACP agent.

use super::{tags, AcpAgentDescriptor, DoctorProbe};
use crate::agents::runtime::models;

const GEMINI_ID: &str = "gemini";

/// Construct the Gemini ACP descriptor.
///
/// Returns a fresh value; the catalog's `LazyLock<Vec<_>>` owns the canonical
/// storage so every caller sees the same instance after first access.
///
/// # Panics
/// Panics if the built-in runtime model registry is missing Gemini. That would
/// mean the ACP descriptor and first-party model catalog drifted apart.
#[must_use]
pub fn descriptor() -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: GEMINI_ID.to_owned(),
        display_name: "Gemini CLI".to_owned(),
        capabilities: vec![
            tags::FS_READ.to_owned(),
            tags::FS_WRITE.to_owned(),
            tags::TERMINAL_SPAWN.to_owned(),
            tags::STREAMING.to_owned(),
            tags::MULTI_TURN.to_owned(),
            tags::REQUIRES_NETWORK.to_owned(),
        ],
        launch_command: "gemini".to_owned(),
        launch_args: vec!["--acp".to_owned()],
        env_passthrough: vec![
            "GEMINI_API_KEY".to_owned(),
            "GOOGLE_API_KEY".to_owned(),
            "GOOGLE_CLOUD_PROJECT".to_owned(),
            "GOOGLE_CLOUD_LOCATION".to_owned(),
            "GOOGLE_APPLICATION_CREDENTIALS".to_owned(),
            "GOOGLE_GENAI_USE_VERTEXAI".to_owned(),
            "GOOGLE_GENAI_API_VERSION".to_owned(),
            "GOOGLE_GEMINI_BASE_URL".to_owned(),
            "GOOGLE_VERTEX_BASE_URL".to_owned(),
            "GEMINI_MODEL".to_owned(),
            "GEMINI_CLI_HOME".to_owned(),
            "GEMINI_CLI_TRUST_WORKSPACE".to_owned(),
        ],
        model_catalog: Some(
            models::catalog_for(GEMINI_ID)
                .expect("built-in Gemini descriptor must have a model catalog")
                .clone(),
        ),
        install_hint: Some(
            "Install an ACP-capable Gemini CLI and authenticate: https://github.com/google-gemini/gemini-cli"
                .to_owned(),
        ),
        doctor_probe: DoctorProbe {
            command: "gemini".to_owned(),
            args: vec!["--version".to_owned()],
        },
        prompt_timeout_seconds: None,
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
    fn doctor_probe_targets_gemini_version() {
        let descriptor = descriptor();
        assert_eq!(descriptor.doctor_probe.command, "gemini");
        assert_eq!(descriptor.doctor_probe.args, vec!["--version"]);
    }

    #[test]
    fn launch_uses_current_acp_flag() {
        let descriptor = descriptor();
        assert_eq!(descriptor.launch_command, "gemini");
        assert_eq!(descriptor.launch_args, vec!["--acp"]);
    }

    #[test]
    fn env_passthrough_covers_auth_and_cli_state() {
        let descriptor = descriptor();
        for name in [
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "GOOGLE_GENAI_USE_VERTEXAI",
            "GEMINI_CLI_HOME",
        ] {
            assert!(
                descriptor.env_passthrough.iter().any(|entry| entry == name),
                "env passthrough missing {name}"
            );
        }
    }

    #[test]
    fn model_catalog_points_at_gemini_models() {
        let descriptor = descriptor();
        let catalog = descriptor.model_catalog.expect("gemini model catalog");
        assert_eq!(catalog.runtime, "gemini");
        assert!(catalog
            .models
            .iter()
            .any(|model| model.id == catalog.default));
    }
}
