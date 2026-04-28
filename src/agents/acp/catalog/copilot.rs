//! Built-in descriptor for GitHub Copilot CLI speaking ACP.
//!
//! Copilot exposes ACP via `copilot --acp --stdio` (public preview, Jan 2026).
//! Doctor-probe richness (auth state, version range) lands with the wider
//! probe shape in Chunk 8; Chunk 1 captures only the fields a basic launch +
//! installation check needs.

use super::{AcpAgentDescriptor, DoctorProbe, tags};

/// Construct the Copilot descriptor.
///
/// Returns a fresh value; the catalog's `LazyLock<Vec<_>>` owns the canonical
/// storage so every caller sees the same instance after first access.
#[must_use]
pub fn descriptor() -> AcpAgentDescriptor {
    AcpAgentDescriptor {
        id: "copilot".to_owned(),
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
        install_hint: Some(
            "Install GitHub Copilot CLI: https://github.com/github/copilot-cli".to_owned(),
        ),
        doctor_probe: DoctorProbe {
            command: "copilot".to_owned(),
            args: vec!["--version".to_owned()],
        },
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
}
