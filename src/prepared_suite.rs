use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// A file to copy from source to prepared location.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedCopy {
    pub source_path: PathBuf,
    pub prepared_path: PathBuf,
}

/// A file to write with generated content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedWrite {
    pub prepared_path: PathBuf,
    pub text: String,
}

/// SHA256 digest of a source file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceDigest {
    pub source_path: String,
    pub digest: String,
}

/// Validation result for a manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestValidation {
    #[serde(default)]
    pub output_path: Option<String>,
    pub status: String,
    #[serde(default)]
    pub checked_at: Option<String>,
    #[serde(default)]
    pub resource_kinds: Vec<String>,
}

/// Reference to a manifest in the prepared suite.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestRef {
    pub manifest_id: String,
    pub scope: String,
    pub source_path: String,
    #[serde(default)]
    pub validation: Option<ManifestValidation>,
    #[serde(default)]
    pub group_id: Option<String>,
    #[serde(default)]
    pub prepared_path: Option<String>,
    #[serde(default)]
    pub digest: Option<String>,
    #[serde(default)]
    pub order: Option<i64>,
    #[serde(default)]
    pub applied: bool,
    #[serde(default)]
    pub applied_at: Option<String>,
    #[serde(default)]
    pub step: Option<String>,
    #[serde(default)]
    pub applied_path: Option<String>,
}

/// A prepared group with its manifests.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreparedGroup {
    pub group_id: String,
    pub source_path: String,
    #[serde(default)]
    pub helm_values: serde_json::Value,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub skip_validation_orders: Vec<i64>,
    #[serde(default)]
    pub manifests: Vec<ManifestRef>,
}

/// The full prepared suite artifact.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreparedSuiteArtifact {
    pub suite_path: String,
    pub profile: String,
    pub prepared_at: String,
    #[serde(default)]
    pub source_digests: Vec<SourceDigest>,
    #[serde(default)]
    pub baselines: Vec<ManifestRef>,
    #[serde(default)]
    pub groups: Vec<PreparedGroup>,
}

impl PreparedSuiteArtifact {
    /// Load from a JSON file.
    ///
    /// # Errors
    /// Returns `CliError` if the file cannot be read or parsed.
    pub fn load(path: &Path) -> Result<Option<Self>, CliError> {
        if !path.exists() {
            return Ok(None);
        }
        let text = fs::read_to_string(path).map_err(|e| CliError {
            code: "KSRCLI014".to_string(),
            message: format!("cannot read file: {}: {e}", path.display()),
            exit_code: 5,
            hint: None,
            details: Some(e.to_string()),
        })?;
        let artifact: Self = serde_json::from_str(&text).map_err(|e| CliError {
            code: "KSRCLI042".to_string(),
            message: format!(
                "invalid suite-author prepared suite payload: {}",
                path.display()
            ),
            exit_code: 5,
            hint: None,
            details: Some(e.to_string()),
        })?;
        Ok(Some(artifact))
    }

    /// Save to the canonical location.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self, path: &Path) -> Result<(), CliError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| CliError {
                code: "KSRCLI014".to_string(),
                message: format!("cannot create directory: {}", parent.display()),
                exit_code: 5,
                hint: None,
                details: Some(e.to_string()),
            })?;
        }
        let json = serde_json::to_string_pretty(self).map_err(|e| CliError {
            code: "KSRCLI042".to_string(),
            message: "failed to serialize prepared suite artifact".to_string(),
            exit_code: 5,
            hint: None,
            details: Some(e.to_string()),
        })?;
        fs::write(path, json).map_err(|e| CliError {
            code: "KSRCLI014".to_string(),
            message: format!("cannot write file: {}", path.display()),
            exit_code: 5,
            hint: None,
            details: Some(e.to_string()),
        })
    }
}

/// Plan for materializing a prepared suite.
#[derive(Debug, Clone)]
pub struct PreparedSuitePlan {
    pub artifact: PreparedSuiteArtifact,
    pub baseline_copies: Vec<PreparedCopy>,
    pub group_writes: Vec<PreparedWrite>,
}

fn extract_section(body: &str, heading: &str) -> Option<String> {
    let pattern = format!("## {heading}");
    let mut start = None;
    for (i, line) in body.lines().enumerate() {
        if let Some(s) = start {
            if line.starts_with("## ") {
                let content: String = body
                    .lines()
                    .skip(s)
                    .take(i - s)
                    .collect::<Vec<_>>()
                    .join("\n");
                return Some(content);
            }
        } else {
            let trimmed = line.trim_end();
            if trimmed == pattern || trimmed.starts_with(&format!("{pattern} ")) {
                start = Some(i + 1);
            }
        }
    }
    start.map(|s| body.lines().skip(s).collect::<Vec<_>>().join("\n"))
}

/// Extract the Configure section from a group body.
#[must_use]
pub fn configure_section(body: &str) -> Option<String> {
    extract_section(body, "Configure")
}

/// Extract the Consume section from a group body.
#[must_use]
pub fn consume_section(body: &str) -> Option<String> {
    extract_section(body, "Consume")
}

fn extract_fenced_blocks(text: &str, lang_prefixes: &[&str]) -> Vec<String> {
    let mut blocks = Vec::new();
    let mut fence_backticks: usize = 0;
    let mut current_block = Vec::new();

    for line in text.lines() {
        if fence_backticks > 0 {
            let closing_len = line.len() - line.trim_start_matches('`').len();
            if closing_len >= fence_backticks && line.trim_start_matches('`').trim().is_empty() {
                let content = current_block.join("\n").trim().to_string();
                if !content.is_empty() {
                    blocks.push(format!("{content}\n"));
                }
                current_block.clear();
                fence_backticks = 0;
            } else {
                current_block.push(line);
            }
        } else if line.starts_with("```") {
            let backtick_len = line.len() - line.trim_start_matches('`').len();
            let tag = &line[backtick_len..];
            let lang = tag.split_whitespace().next().unwrap_or("");
            if lang_prefixes.iter().any(|p| lang.eq_ignore_ascii_case(p)) {
                fence_backticks = backtick_len;
                current_block.clear();
            }
        }
    }
    blocks
}

/// Extract YAML code blocks from text.
#[must_use]
pub fn yaml_blocks(text: &str) -> Vec<String> {
    extract_fenced_blocks(text, &["yaml", "yml"])
}

/// Extract shell code blocks from text.
#[must_use]
pub fn shell_blocks(text: &str) -> Vec<String> {
    extract_fenced_blocks(text, &["bash", "sh"])
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- configure_section tests --

    #[test]
    fn configure_section_extracts_content() {
        let body = "## Configure\napiVersion: v1\nkind: Namespace\n## Consume\nkubectl apply\n";
        let section = configure_section(body);
        assert!(section.is_some());
        let s = section.unwrap();
        assert!(s.contains("apiVersion: v1"));
        assert!(!s.contains("kubectl apply"));
    }

    #[test]
    fn configure_section_returns_none_when_missing() {
        let body = "## Consume\nkubectl apply\n";
        assert!(configure_section(body).is_none());
    }

    #[test]
    fn configure_section_captures_until_next_heading() {
        let body = "## Configure\nline1\nline2\n## Debug\nline3\n";
        let section = configure_section(body).unwrap();
        assert!(section.contains("line1"));
        assert!(section.contains("line2"));
        assert!(!section.contains("line3"));
    }

    #[test]
    fn configure_section_captures_to_end_if_last() {
        let body = "## Other\nstuff\n## Configure\nline1\nline2\n";
        let section = configure_section(body).unwrap();
        assert!(section.contains("line1"));
        assert!(section.contains("line2"));
    }

    // -- consume_section tests --

    #[test]
    fn consume_section_extracts_content() {
        let body =
            "## Configure\nyaml stuff\n## Consume\nkubectl apply -f 01.yaml\n## Debug\ncheck\n";
        let section = consume_section(body).unwrap();
        assert!(section.contains("kubectl apply"));
        assert!(!section.contains("yaml stuff"));
        assert!(!section.contains("check"));
    }

    #[test]
    fn consume_section_returns_none_when_missing() {
        let body = "## Configure\nstuff\n";
        assert!(consume_section(body).is_none());
    }

    // -- yaml_blocks tests --

    #[test]
    fn yaml_blocks_extracts_yaml_fenced_blocks() {
        let text = "some text\n```yaml\napiVersion: v1\nkind: Namespace\n```\nmore text\n";
        let blocks = yaml_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("apiVersion: v1"));
        assert!(blocks[0].ends_with('\n'));
    }

    #[test]
    fn yaml_blocks_extracts_yml_variant() {
        let text = "```yml\nkey: value\n```\n";
        let blocks = yaml_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("key: value"));
    }

    #[test]
    fn yaml_blocks_skips_empty_blocks() {
        let text = "```yaml\n\n```\n```yaml\nreal: content\n```\n";
        let blocks = yaml_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("real: content"));
    }

    #[test]
    fn yaml_blocks_extracts_multiple() {
        let text = "```yaml\nfirst: 1\n```\ntext\n```yaml\nsecond: 2\n```\n";
        let blocks = yaml_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert!(blocks[0].contains("first: 1"));
        assert!(blocks[1].contains("second: 2"));
    }

    #[test]
    fn yaml_blocks_ignores_non_yaml() {
        let text = "```bash\necho hello\n```\n```yaml\nkey: val\n```\n";
        let blocks = yaml_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("key: val"));
    }

    // -- shell_blocks tests --

    #[test]
    fn shell_blocks_extracts_bash() {
        let text = "```bash\necho hello\n```\n";
        let blocks = shell_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("echo hello"));
    }

    #[test]
    fn shell_blocks_extracts_sh() {
        let text = "```sh\nls -la\n```\n";
        let blocks = shell_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("ls -la"));
    }

    #[test]
    fn shell_blocks_ignores_yaml() {
        let text = "```yaml\nkey: val\n```\n```bash\necho hi\n```\n";
        let blocks = shell_blocks(text);
        assert_eq!(blocks.len(), 1);
        assert!(blocks[0].contains("echo hi"));
    }

    // -- PreparedSuiteArtifact load/save tests --

    #[test]
    fn load_returns_none_for_missing_file() {
        let result = PreparedSuiteArtifact::load(Path::new("/nonexistent/path.json"));
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("artifacts").join("prepared-suite.json");

        let artifact = PreparedSuiteArtifact {
            suite_path: "/tmp/suite.md".to_string(),
            profile: "single-zone".to_string(),
            prepared_at: "2026-03-13T10:00:00Z".to_string(),
            source_digests: vec![SourceDigest {
                source_path: "suite.md".to_string(),
                digest: "suite-sha".to_string(),
            }],
            baselines: vec![ManifestRef {
                manifest_id: "baseline/namespace.yaml".to_string(),
                scope: "baseline".to_string(),
                source_path: "baseline/namespace.yaml".to_string(),
                validation: Some(ManifestValidation {
                    output_path: Some(
                        "manifests/prepared/baseline/baseline/namespace.validate.txt".to_string(),
                    ),
                    status: "pending".to_string(),
                    checked_at: None,
                    resource_kinds: vec![],
                }),
                group_id: None,
                prepared_path: Some(
                    "manifests/prepared/baseline/baseline/namespace.yaml".to_string(),
                ),
                digest: Some("baseline-sha".to_string()),
                order: None,
                applied: true,
                applied_at: Some("2026-03-13T10:01:00Z".to_string()),
                step: None,
                applied_path: None,
            }],
            groups: vec![PreparedGroup {
                group_id: "g01".to_string(),
                source_path: "groups/g01.md".to_string(),
                helm_values: serde_json::json!({"kuma.controlPlane.replicas": 1}),
                restart_namespaces: vec![],
                skip_validation_orders: vec![],
                manifests: vec![ManifestRef {
                    manifest_id: "g01:01".to_string(),
                    scope: "group".to_string(),
                    source_path: "groups/g01.md".to_string(),
                    group_id: Some("g01".to_string()),
                    validation: Some(ManifestValidation {
                        output_path: Some(
                            "manifests/prepared/groups/g01/01.validate.txt".to_string(),
                        ),
                        status: "pending".to_string(),
                        checked_at: None,
                        resource_kinds: vec![],
                    }),
                    prepared_path: Some("manifests/prepared/groups/g01/01.yaml".to_string()),
                    digest: Some("group-sha".to_string()),
                    order: Some(1),
                    applied: false,
                    applied_at: None,
                    step: None,
                    applied_path: None,
                }],
            }],
        };

        artifact.save(&path).unwrap();
        let loaded = PreparedSuiteArtifact::load(&path).unwrap().unwrap();
        assert_eq!(artifact, loaded);
    }

    #[test]
    fn load_parses_minimal_artifact() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("suite.json");
        let json = serde_json::json!({
            "suite_path": "/tmp/suite.md",
            "profile": "single-zone",
            "prepared_at": "unknown"
        });
        fs::write(&path, serde_json::to_string(&json).unwrap()).unwrap();

        let artifact = PreparedSuiteArtifact::load(&path).unwrap().unwrap();
        assert_eq!(artifact.suite_path, "/tmp/suite.md");
        assert_eq!(artifact.profile, "single-zone");
        assert_eq!(artifact.prepared_at, "unknown");
        assert!(artifact.baselines.is_empty());
        assert!(artifact.groups.is_empty());
        assert!(artifact.source_digests.is_empty());
    }

    #[test]
    fn load_parses_full_artifact_with_groups() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("suite.json");
        let json = serde_json::json!({
            "suite_path": "/tmp/suite.md",
            "profile": "single-zone",
            "prepared_at": "2026-03-13T10:00:00Z",
            "source_digests": [
                {"source_path": "suite.md", "digest": "suite-sha"}
            ],
            "baselines": [{
                "manifest_id": "baseline/namespace.yaml",
                "scope": "baseline",
                "source_path": "baseline/namespace.yaml",
                "prepared_path": "manifests/prepared/baseline/baseline/namespace.yaml",
                "digest": "baseline-sha",
                "validation": {
                    "output_path": "manifests/prepared/baseline/baseline/namespace.validate.txt",
                    "status": "passed"
                }
            }],
            "groups": [{
                "group_id": "g01",
                "source_path": "groups/g01.md",
                "helm_values": {"kuma.controlPlane.replicas": 1},
                "manifests": [{
                    "manifest_id": "g01:01",
                    "scope": "group",
                    "source_path": "groups/g01.md",
                    "group_id": "g01",
                    "prepared_path": "manifests/prepared/groups/g01/01.yaml",
                    "digest": "group-sha",
                    "order": 1,
                    "validation": {
                        "output_path": "manifests/prepared/groups/g01/01.validate.txt",
                        "status": "pending"
                    }
                }]
            }]
        });
        fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

        let artifact = PreparedSuiteArtifact::load(&path).unwrap().unwrap();
        assert_eq!(artifact.source_digests.len(), 1);
        assert_eq!(artifact.source_digests[0].digest, "suite-sha");
        assert_eq!(artifact.baselines.len(), 1);
        assert_eq!(artifact.baselines[0].scope, "baseline");
        assert_eq!(
            artifact.baselines[0].validation.as_ref().unwrap().status,
            "passed"
        );
        assert_eq!(artifact.groups.len(), 1);
        assert_eq!(artifact.groups[0].group_id, "g01");
        assert_eq!(artifact.groups[0].manifests.len(), 1);
        assert_eq!(artifact.groups[0].manifests[0].scope, "group");
        assert_eq!(
            artifact.groups[0].manifests[0].group_id.as_deref(),
            Some("g01")
        );
        assert_eq!(artifact.groups[0].manifests[0].order, Some(1));
    }

    #[test]
    fn serialized_artifact_contains_expected_fields() {
        let artifact = PreparedSuiteArtifact {
            suite_path: "/tmp/suite.md".to_string(),
            profile: "single-zone".to_string(),
            prepared_at: "2026-03-13T10:00:00Z".to_string(),
            source_digests: vec![SourceDigest {
                source_path: "suite.md".to_string(),
                digest: "suite-sha".to_string(),
            }],
            baselines: vec![],
            groups: vec![PreparedGroup {
                group_id: "g01".to_string(),
                source_path: "groups/g01.md".to_string(),
                helm_values: serde_json::json!({}),
                restart_namespaces: vec![],
                skip_validation_orders: vec![],
                manifests: vec![ManifestRef {
                    manifest_id: "g01:01".to_string(),
                    scope: "group".to_string(),
                    source_path: "groups/g01.md".to_string(),
                    group_id: Some("g01".to_string()),
                    validation: None,
                    prepared_path: Some("manifests/prepared/groups/g01/01.yaml".to_string()),
                    digest: Some("group-sha".to_string()),
                    order: Some(1),
                    applied: false,
                    applied_at: None,
                    step: None,
                    applied_path: None,
                }],
            }],
        };

        let value = serde_json::to_value(&artifact).unwrap();
        let obj = value.as_object().unwrap();
        assert_eq!(obj["suite_path"], "/tmp/suite.md");
        assert_eq!(obj["profile"], "single-zone");

        let groups = obj["groups"].as_array().unwrap();
        let g0 = groups[0].as_object().unwrap();
        assert_eq!(g0["source_path"], "groups/g01.md");

        let manifests = g0["manifests"].as_array().unwrap();
        let m0 = manifests[0].as_object().unwrap();
        assert_eq!(m0["scope"], "group");
        assert_eq!(m0["group_id"], "g01");
        assert_eq!(m0["order"], 1);
    }
}
