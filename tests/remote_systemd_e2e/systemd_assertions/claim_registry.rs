use std::path::Path;

use serde::Deserialize;

use super::{root_path_matches, sudo};

const BINARY_CLAIM_REGISTRY: &str = "/var/lib/harness/remote-systemd/.binary-claims.json";
const REGISTRY_VERSION: u32 = 1;
const CLAIM_VERSION: u32 = 1;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RegistryDocument {
    registry_version: u32,
    claims: Vec<ClaimRecord>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimRecord {
    claim_version: u32,
    unit: String,
    #[serde(rename = "binary_path")]
    _binary_path: String,
    #[serde(rename = "resolved_binary_path")]
    _resolved_binary_path: String,
    #[serde(rename = "parent_device")]
    _parent_device: u64,
    #[serde(rename = "parent_inode")]
    _parent_inode: u64,
    #[serde(rename = "entry_name")]
    _entry_name: String,
}

pub(super) fn assert_binary_claim_absent(unit: &str) -> Result<(), String> {
    let registry_path = Path::new(BINARY_CLAIM_REGISTRY);
    if root_path_matches("-L", registry_path)? {
        return Err(format!(
            "systemd binary claim registry must not be a symlink: {BINARY_CLAIM_REGISTRY}"
        ));
    }
    if !root_path_matches("-e", registry_path)? {
        return Ok(());
    }
    if !root_path_matches("-f", registry_path)? {
        return Err(format!(
            "systemd binary claim registry is not a regular file: {BINARY_CLAIM_REGISTRY}"
        ));
    }
    let output = sudo(["cat", BINARY_CLAIM_REGISTRY])
        .output()
        .map_err(|error| format!("read systemd binary claim registry: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "read systemd binary claim registry exited with {}; stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    validate_claim_absent(unit, &output.stdout)
}

fn validate_claim_absent(unit: &str, contents: &[u8]) -> Result<(), String> {
    let document = serde_json::from_slice::<RegistryDocument>(contents)
        .map_err(|error| format!("decode systemd binary claim registry: {error}"))?;
    if document.registry_version != REGISTRY_VERSION {
        return Err(format!(
            "unsupported systemd binary claim registry version {}",
            document.registry_version
        ));
    }
    for claim in document.claims {
        if claim.claim_version != CLAIM_VERSION {
            return Err(format!(
                "unsupported systemd binary ownership claim version {} for unit {}",
                claim.claim_version, claim.unit
            ));
        }
        if claim.unit == unit {
            return Err(format!(
                "systemd cleanup left a binary ownership claim for {unit}"
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_claim_absent;

    const VALID_CLAIM: &str = r#"{
        "claim_version": 1,
        "unit": "harness-remote-e2e-other",
        "binary_path": "/usr/local/bin/harness-remote-e2e-other",
        "resolved_binary_path": "/usr/local/bin/harness-remote-e2e-other",
        "parent_device": 1,
        "parent_inode": 2,
        "entry_name": "harness-remote-e2e-other"
    }"#;

    #[test]
    fn valid_registry_without_target_claim_passes() {
        let registry = format!(r#"{{"registry_version":1,"claims":[{VALID_CLAIM}]}}"#);
        validate_claim_absent("harness-remote-e2e-target", registry.as_bytes())
            .expect("unrelated valid claim");
    }

    #[test]
    fn target_claim_fails() {
        let registry = format!(r#"{{"registry_version":1,"claims":[{VALID_CLAIM}]}}"#)
            .replace("harness-remote-e2e-other", "harness-remote-e2e-target");
        let error = validate_claim_absent("harness-remote-e2e-target", registry.as_bytes())
            .expect_err("target claim must remain visible");
        assert!(error.contains("left a binary ownership claim"));
    }

    #[test]
    fn malformed_or_unsupported_registry_fails_closed() {
        for registry in [
            r#"{"registry_version":2,"claims":[]}"#,
            r#"{"registry_version":1,"claims":[{"claim_version":2,"unit":"target","binary_path":"/bin/target","resolved_binary_path":"/bin/target","parent_device":1,"parent_inode":2,"entry_name":"target"}]}"#,
            r#"{"registry_version":1,"claims":[{"claim_version":1,"unit":"target"}]}"#,
            r#"{"registry_version":1,"claims":[],"unknown":true}"#,
        ] {
            assert!(validate_claim_absent("target", registry.as_bytes()).is_err());
        }
    }
}
