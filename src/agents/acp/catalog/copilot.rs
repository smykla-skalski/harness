//! Built-in descriptor for GitHub Copilot CLI speaking ACP.
//!
//! Copilot exposes ACP via `copilot --acp --stdio` (public preview, Jan 2026).
//! Doctor-probe richness (auth state, version range) lands with the wider
//! probe shape in Chunk 8; Chunk 1 captures only the fields a basic launch +
//! installation check needs.

use super::{AcpAgentDescriptor, DoctorProbe, tags};
use crate::agents::runtime::models;

const COPILOT_ID: &str = "copilot";

/// Construct the Copilot descriptor.
///
/// Returns a fresh value; the catalog's `LazyLock<Vec<_>>` owns the canonical
/// storage so every caller sees the same instance after first access.
///
/// # Panics
/// Panics if the built-in runtime model registry is missing Copilot. That is a
/// harness invariant breach: the first-party ACP descriptor and first-party
/// model catalog must ship together.
#[must_use]
pub fn descriptor() -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: COPILOT_ID.to_owned(),
        display_name: "GitHub Copilot".to_owned(),
        capabilities: vec![
            tags::FS_READ.to_owned(),
            tags::FS_WRITE.to_owned(),
            tags::TERMINAL_SPAWN.to_owned(),
            tags::STREAMING.to_owned(),
            tags::MULTI_TURN.to_owned(),
        ],
        launch_command: "copilot".to_owned(),
        launch_args: vec!["--acp".to_owned(), "--stdio".to_owned()],
        env_passthrough: vec![
            "COPILOT_GITHUB_TOKEN".to_owned(),
            "GH_TOKEN".to_owned(),
            "GITHUB_TOKEN".to_owned(),
        ],
        model_catalog: Some(
            models::catalog_for(COPILOT_ID)
                .expect("built-in Copilot descriptor must have a model catalog")
                .clone(),
        ),
        install_hint: Some(
            "Install GitHub Copilot CLI: https://github.com/github/copilot-cli".to_owned(),
        ),
        doctor_probe: DoctorProbe {
            command: "copilot".to_owned(),
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
    fn doctor_probe_targets_copilot_version() {
        let descriptor = descriptor();
        assert_eq!(descriptor.doctor_probe.command, "copilot");
        assert_eq!(descriptor.doctor_probe.args, vec!["--version"]);
    }

    #[test]
    fn install_hint_is_actionable() {
        let descriptor = descriptor();
        let hint = descriptor.install_hint.as_deref().expect("hint present");
        assert!(hint.to_lowercase().contains("copilot"));
        assert!(hint.contains("github"));
    }

    #[test]
    fn model_catalog_points_at_copilot_models() {
        let descriptor = descriptor();
        let catalog = descriptor.model_catalog.expect("copilot model catalog");
        assert_eq!(catalog.runtime, "copilot");
        assert!(
            catalog
                .models
                .iter()
                .any(|model| model.id == catalog.default)
        );
    }
}
