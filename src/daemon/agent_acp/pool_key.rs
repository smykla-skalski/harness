use std::collections::BTreeMap;
use std::env;
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::agents::acp::catalog::AcpAgentDescriptor;
use crate::daemon::agent_acp::manager::AcpAgentStartRequest;

const FINGERPRINT_ENV_KEYS: &[&str] = &[
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

impl AcpProcessPoolKey {
    pub(super) fn from_spawn_inputs(
        descriptor: &AcpAgentDescriptor,
        request: &AcpAgentStartRequest,
        project_dir: &Path,
    ) -> Self {
        let mode = if request.record_permissions {
            "recording"
        } else {
            "daemon_bridge"
        };
        let env_fingerprint = hash_env_fingerprint(&descriptor.env_passthrough);
        let canonical = format!(
            "agent={};command={};args={};root={};permission_mode={};env={}",
            descriptor.id,
            descriptor.launch_command,
            descriptor.launch_args.join("\u{1f}"),
            project_dir.display(),
            mode,
            env_fingerprint
        );
        Self { canonical }
    }

    pub(super) fn as_str(&self) -> &str {
        &self.canonical
    }
}

fn hash_env_fingerprint(descriptor_env_keys: &[String]) -> String {
    let mut keys = FINGERPRINT_ENV_KEYS
        .iter()
        .copied()
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    keys.extend(descriptor_env_keys.iter().cloned());
    keys.sort();
    keys.dedup();

    let mut values = BTreeMap::new();
    for key in keys {
        values.insert(key.clone(), env::var(&key).ok().map(|v| secret_hash(&v)));
    }
    let json = serde_json::to_vec(&values).unwrap_or_default();
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
        let first = temp_env::with_var("OPENAI_API_KEY", Some("a"), || {
            hash_env_fingerprint(&[])
        });
        let second = temp_env::with_var("OPENAI_API_KEY", Some("b"), || {
            hash_env_fingerprint(&[])
        });
        assert_ne!(first, second);
    }

    #[test]
    fn fingerprint_ignores_untracked_values() {
        let first = temp_env::with_var("HARNESS_UNTRACKED_TEST_VAR", Some("a"), || {
            hash_env_fingerprint(&[])
        });
        let second = temp_env::with_var("HARNESS_UNTRACKED_TEST_VAR", Some("b"), || {
            hash_env_fingerprint(&[])
        });
        assert_eq!(first, second);
    }
}
