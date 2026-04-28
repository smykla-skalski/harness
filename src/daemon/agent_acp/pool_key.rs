use std::collections::BTreeMap;
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::agents::acp::catalog::AcpAgentDescriptor;
use crate::agents::acp::connection::SpawnConfig;
use crate::daemon::agent_acp::manager::AcpAgentStartRequest;

const IDENTITY_ENV_KEYS: &[&str] = &[
    "PATH",
    "SHELL",
    "HOME",
    "USER",
    "LOGNAME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "CODEX_HOME",
    "CLAUDE_CONFIG_DIR",
    "GEMINI_HOME",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GOOGLE_API_KEY",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct AcpProcessPoolKey {
    canonical: String,
}

#[derive(serde::Serialize)]
struct IdentityPayload {
    agent_descriptor_id: String,
    resolved_command: String,
    args: Vec<String>,
    canonical_root: String,
    permission_mode: String,
    env_fingerprint: String,
}

impl AcpProcessPoolKey {
    /// Build a fail-closed process identity key from concrete spawn inputs.
    ///
    /// The key must change whenever process behavior may change.
    /// Keep this payload typed and opaque to avoid coupling external callers to
    /// implementation details of the reuse contract.
    ///
    /// Identity protocol:
    /// - stable dimensions: descriptor, resolved command, args, canonical root, permission mode;
    /// - env dimension: curated allowlist + descriptor passthrough entries;
    /// - unknown env dimensions are intentionally excluded in stage 1 to avoid
    ///   noisy oversplitting, and must be added explicitly before pooling depends
    ///   on them for safety.
    pub(super) fn from_spawn_inputs(
        descriptor: &AcpAgentDescriptor,
        request: &AcpAgentStartRequest,
        spawn: &SpawnConfig,
        project_dir: &Path,
    ) -> Self {
        let mode = if request.record_permissions {
            "recording"
        } else {
            "daemon_bridge"
        };
        let env_fingerprint = hash_identity_environment(
            spawn.effective_env_for_identity(),
            &descriptor.env_passthrough,
        );
        let canonical_root = project_dir
            .canonicalize()
            .unwrap_or_else(|_| project_dir.to_path_buf())
            .display()
            .to_string();
        let payload = IdentityPayload {
            agent_descriptor_id: descriptor.id.clone(),
            resolved_command: spawn.resolved_command_for_identity(),
            args: spawn.args.clone(),
            canonical_root,
            permission_mode: mode.to_string(),
            env_fingerprint,
        };
        let canonical = format!("acp-process-{}", hash_identity_payload(&payload));
        Self { canonical }
    }

    pub(super) fn as_str(&self) -> &str {
        &self.canonical
    }
}

fn hash_identity_environment(
    values: Vec<(String, String)>,
    descriptor_env_keys: &[String],
) -> String {
    let mut allowed = IDENTITY_ENV_KEYS
        .iter()
        .copied()
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    allowed.extend(descriptor_env_keys.iter().cloned());
    allowed.sort();
    allowed.dedup();

    let allowed = allowed.into_iter().collect::<std::collections::BTreeSet<_>>();
    let mut hashed = BTreeMap::new();
    for (key, value) in values {
        if allowed.contains(&key) {
            hashed.insert(key, secret_hash(&value));
        }
    }
    let json = serde_json::to_vec(&hashed).unwrap_or_default();
    hex::encode(Sha256::digest(json))
}

fn hash_identity_payload(payload: &IdentityPayload) -> String {
    let json = serde_json::to_vec(payload).unwrap_or_default();
    hex::encode(Sha256::digest(json))
}

fn secret_hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_changes_when_tracked_value_changes() {
        let first =
            temp_env::with_var("OPENAI_API_KEY", Some("a"), || hash_identity_environment(vec![
                ("OPENAI_API_KEY".to_string(), "a".to_string()),
            ], &[]));
        let second =
            temp_env::with_var("OPENAI_API_KEY", Some("b"), || hash_identity_environment(vec![
                ("OPENAI_API_KEY".to_string(), "b".to_string()),
            ], &[]));
        assert_ne!(first, second);
    }

    #[test]
    fn fingerprint_ignores_unlisted_env_values() {
        let first = hash_identity_environment(
            vec![("NOISE".to_string(), "a".to_string())],
            &[],
        );
        let second = hash_identity_environment(
            vec![("NOISE".to_string(), "b".to_string())],
            &[],
        );
        assert_eq!(first, second);
    }
}
