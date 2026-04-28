//! Static catalog of ACP agent descriptors.
//!
//! Chunk 1 ships the descriptor type and the Copilot entry. Chunk 12 adds the
//! cookbook second descriptor as a falsification test on the catalog claim;
//! Chunk 13 layers the user-defined merge from `~/.config/harness/acp-agents.toml`.
//!
//! Falsification rule, restated honestly: a new built-in descriptor should be
//! exactly one new file plus a one-line `mod` declaration and a one-line
//! registry entry below. If a second descriptor needs anything else, the
//! shape is wrong; rework before merging.

pub mod copilot;
pub mod tags;

use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use crate::agents::runtime::models::RuntimeModelCatalog;

pub use tags::CapabilityTag;

/// Doctor probe shape: how to ask whether the agent is installed and reachable.
///
/// Chunk 8's `harness doctor` runs the probe per descriptor and surfaces the
/// result to the picker. Chunk 1's contract: zero exit code from `command args`
/// means "binary present"; richer states (`auth_state`, version range) land in
/// Chunk 8 alongside the wire-shaped `Probe { binary_present, auth_state, version, install_hint }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DoctorProbe {
    /// Executable to invoke (looked up via `$PATH`).
    pub command: String,
    /// Arguments passed to the executable.
    pub args: Vec<String>,
}

/// Declarative description of an ACP agent the harness knows how to launch.
///
/// One descriptor maps to one row in the New Session sheet. The shape stays
/// narrow on purpose; the falsification rule above forces every new field to
/// earn its place across both built-in and user-defined entries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AcpAgentDescriptor {
    /// Stable identifier used in storage and over the wire (e.g. `copilot`).
    pub id: String,
    /// Human-readable label rendered in the picker (e.g. `GitHub Copilot`).
    pub display_name: String,
    /// Free-form capability tags; well-known values live in [`tags`].
    pub capabilities: Vec<CapabilityTag>,
    /// Executable that speaks ACP over stdio.
    pub launch_command: String,
    /// Arguments that put the executable into ACP/stdio mode.
    pub launch_args: Vec<String>,
    /// Names of environment variables forwarded to the agent process.
    pub env_passthrough: Vec<String>,
    /// Optional model catalog exposed by this ACP agent.
    ///
    /// Copilot has a curated model catalog today. Other ACP agents may expose
    /// a single implicit model, so this remains optional until the config-file
    /// merge path proves every descriptor needs model selection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_catalog: Option<RuntimeModelCatalog>,
    /// Optional short instruction surfaced when the doctor probe reports the
    /// binary missing. `None` is allowed so user-defined entries (Chunk 13)
    /// can omit it.
    #[serde(default)]
    pub install_hint: Option<String>,
    /// Probe used by `harness doctor` to test installation.
    pub doctor_probe: DoctorProbe,
    /// Maximum time allowed for a single `session/prompt` call. `None` uses the
    /// default of 10 minutes. Per-descriptor override for long-running agents.
    #[serde(default)]
    pub prompt_timeout_seconds: Option<u64>,
}

static BUILTIN_DESCRIPTORS: LazyLock<Vec<AcpAgentDescriptor>> =
    LazyLock::new(|| vec![copilot::descriptor()]);

/// Return every built-in descriptor in stable order.
///
/// The returned vector contains references into process-wide storage. Chunk
/// 13's user-defined merge layer can append owned descriptors without changing
/// the built-in registry shape.
#[must_use]
pub fn acp_agents() -> Vec<&'static AcpAgentDescriptor> {
    BUILTIN_DESCRIPTORS.iter().collect()
}

/// Look up a built-in descriptor by [`AcpAgentDescriptor::id`].
#[must_use]
pub fn find_builtin(id: &str) -> Option<&'static AcpAgentDescriptor> {
    BUILTIN_DESCRIPTORS.iter().find(|d| d.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_contains_copilot() {
        let agents = acp_agents();
        let copilot = agents
            .iter()
            .find(|d| d.id == "copilot")
            .expect("copilot descriptor in catalog");
        assert_eq!(copilot.display_name, "GitHub Copilot");
        assert_eq!(copilot.launch_command, "copilot");
        assert_eq!(copilot.launch_args, vec!["--acp", "--stdio"]);
    }

    #[test]
    fn catalog_returns_static_descriptor_references() {
        let agents = acp_agents();
        let copilot = agents
            .into_iter()
            .find(|d| d.id == "copilot")
            .expect("copilot descriptor in catalog");
        let found = find_builtin("copilot").expect("found by id");
        assert!(std::ptr::eq(copilot, found));
    }

    #[test]
    fn find_builtin_returns_known_descriptor() {
        let descriptor = find_builtin("copilot").expect("found by id");
        assert_eq!(descriptor.id, "copilot");
    }

    #[test]
    fn find_builtin_returns_none_for_unknown_id() {
        assert!(find_builtin("nope").is_none());
    }

    #[test]
    fn descriptor_round_trips_through_json() {
        let original = copilot::descriptor();
        let json = serde_json::to_string(&original).expect("serialise descriptor");
        let parsed: AcpAgentDescriptor =
            serde_json::from_str(&json).expect("deserialise descriptor");
        assert_eq!(original, parsed);
    }

    #[test]
    fn descriptor_omits_install_hint_when_absent() {
        let mut descriptor = copilot::descriptor();
        descriptor.install_hint = None;
        let json = serde_json::to_string(&descriptor).expect("serialise");
        let parsed: AcpAgentDescriptor =
            serde_json::from_str(&json).expect("deserialise without install_hint");
        assert_eq!(parsed.install_hint, None);
    }

    #[test]
    fn descriptor_defaults_model_catalog_when_absent() {
        let json = serde_json::json!({
            "id": "custom",
            "display_name": "Custom ACP",
            "capabilities": [],
            "launch_command": "custom-acp",
            "launch_args": [],
            "env_passthrough": [],
            "doctor_probe": {
                "command": "custom-acp",
                "args": ["--version"]
            }
        });
        let parsed: AcpAgentDescriptor =
            serde_json::from_value(json).expect("deserialise descriptor without model catalog");
        assert_eq!(parsed.model_catalog, None);
    }

    #[test]
    fn copilot_capabilities_use_well_known_tags() {
        let copilot = find_builtin("copilot").expect("copilot exists");
        assert!(copilot.capabilities.iter().any(|t| t == tags::FS_READ));
        assert!(copilot.capabilities.iter().any(|t| t == tags::FS_WRITE));
        assert!(
            copilot
                .capabilities
                .iter()
                .any(|t| t == tags::TERMINAL_SPAWN)
        );
        assert!(copilot.capabilities.iter().any(|t| t == tags::STREAMING));
        assert!(copilot.capabilities.iter().any(|t| t == tags::MULTI_TURN));
    }

    #[test]
    fn copilot_env_passthrough_covers_documented_tokens() {
        let copilot = find_builtin("copilot").expect("copilot exists");
        for token in ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
            assert!(
                copilot.env_passthrough.iter().any(|name| name == token),
                "env passthrough missing {token}"
            );
        }
    }
}
