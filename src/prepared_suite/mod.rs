mod builders;
mod digest;
mod extraction;
mod manifest;

pub use digest::SourceDigest;
pub use extraction::{configure_section, consume_section, shell_blocks, yaml_blocks};
pub use manifest::{
    HelmValues, ManifestRef, ManifestScope, ManifestValidation, PreparedCopy, PreparedGroup,
    PreparedWrite, ValidationStatus,
};

use std::path::Path;

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use builders::{build_baseline_plan, build_group_plan, copy_prepared_file};
use digest::source_digest;

use crate::errors::{CliError, CliErrorKind};
use crate::io::{read_json_typed, write_json_pretty, write_text};
use crate::schema::SuiteSpec;

use crate::context::RunLayout;

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
        let artifact: Self = read_json_typed(path).map_err(|e| {
            CliErrorKind::authoring_payload_invalid("prepared suite", path.display().to_string())
                .with_details(e.to_string())
        })?;
        Ok(Some(artifact))
    }

    /// Save to the canonical location.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn save(&self, path: &Path) -> Result<(), CliError> {
        write_json_pretty(path, self).map_err(|e| {
            CliErrorKind::missing_file(path.display().to_string()).with_details(e.to_string())
        })
    }

    #[must_use]
    pub fn group(&self, group_id: &str) -> Option<&PreparedGroup> {
        self.groups.iter().find(|group| group.group_id == group_id)
    }

    pub fn iter_manifests(&self) -> impl Iterator<Item = &ManifestRef> {
        self.baselines
            .iter()
            .chain(self.groups.iter().flat_map(|group| group.manifests.iter()))
    }

    pub fn iter_manifests_mut(&mut self) -> impl Iterator<Item = &mut ManifestRef> {
        self.baselines.iter_mut().chain(
            self.groups
                .iter_mut()
                .flat_map(|group| group.manifests.iter_mut()),
        )
    }

    #[must_use]
    pub fn manifest_by_prepared_path(&self, prepared_path: &str) -> Option<&ManifestRef> {
        self.iter_manifests()
            .find(|manifest| manifest.prepared_path.as_deref() == Some(prepared_path))
    }

    pub fn manifest_mut_by_prepared_path(
        &mut self,
        prepared_path: &str,
    ) -> Option<&mut ManifestRef> {
        self.iter_manifests_mut()
            .find(|manifest| manifest.prepared_path.as_deref() == Some(prepared_path))
    }
}

/// Plan for materializing a prepared suite.
#[derive(Debug, Clone)]
pub struct PreparedSuitePlan {
    pub artifact: PreparedSuiteArtifact,
    pub baseline_copies: Vec<PreparedCopy>,
    pub group_writes: Vec<PreparedWrite>,
    pub validation_writes: Vec<PreparedWrite>,
}

impl PreparedSuitePlan {
    /// Build the prepared-suite materialization plan for a run.
    ///
    /// # Errors
    /// Returns `CliError` if suite files cannot be loaded or hashed.
    pub fn build(
        layout: &RunLayout,
        suite: &SuiteSpec,
        profile: &str,
        prepared_at: &str,
    ) -> Result<Self, CliError> {
        let mut source_digests = vec![source_digest(&suite.path, "suite.md")?];
        let mut groups = Vec::new();
        let mut group_writes = Vec::new();
        let baseline_plan = build_baseline_plan(layout, suite)?;
        source_digests.extend(baseline_plan.source_digests);
        let mut validation_writes = baseline_plan.validation_writes;

        let group_plans: Result<Vec<_>, CliError> = suite
            .frontmatter
            .groups
            .par_iter()
            .map(|group_rel| build_group_plan(layout, suite, profile, group_rel))
            .collect();
        for maybe_plan in group_plans? {
            let Some(group_plan) = maybe_plan else {
                continue;
            };
            source_digests.push(group_plan.source_digest);
            groups.push(group_plan.group);
            group_writes.extend(group_plan.group_writes);
            validation_writes.extend(group_plan.validation_writes);
        }

        Ok(Self {
            artifact: PreparedSuiteArtifact {
                suite_path: suite.path.display().to_string(),
                profile: profile.to_string(),
                prepared_at: prepared_at.to_string(),
                source_digests,
                baselines: baseline_plan.baselines,
                groups,
            },
            baseline_copies: baseline_plan.baseline_copies,
            group_writes,
            validation_writes,
        })
    }

    /// Materialize the prepared manifests and validation notes to disk.
    ///
    /// # Errors
    /// Returns `CliError` on IO failure.
    pub fn materialize(&self) -> Result<(), CliError> {
        for copy in &self.baseline_copies {
            copy_prepared_file(copy)?;
        }
        for write in self
            .group_writes
            .iter()
            .chain(self.validation_writes.iter())
        {
            write_text(&write.prepared_path, write.text.as_ref())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::cognitive_complexity)]

    use super::*;
    use std::fs;

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
                scope: ManifestScope::Baseline,
                source_path: "baseline/namespace.yaml".to_string(),
                validation: Some(ManifestValidation {
                    output_path: Some(
                        "manifests/prepared/baseline/baseline/namespace.validate.txt".to_string(),
                    ),
                    status: ValidationStatus::Pending,
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
                helm_values: HelmValues::from([(
                    "kuma.controlPlane.replicas".to_string(),
                    serde_json::json!(1),
                )]),
                restart_namespaces: vec![],
                skip_validation_orders: vec![],
                manifests: vec![ManifestRef {
                    manifest_id: "g01:01".to_string(),
                    scope: ManifestScope::Group,
                    source_path: "groups/g01.md".to_string(),
                    group_id: Some("g01".to_string()),
                    validation: Some(ManifestValidation {
                        output_path: Some(
                            "manifests/prepared/groups/g01/01.validate.txt".to_string(),
                        ),
                        status: ValidationStatus::Pending,
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
        assert_eq!(artifact.baselines[0].scope, ManifestScope::Baseline);
        assert_eq!(
            artifact.baselines[0].validation.as_ref().unwrap().status,
            ValidationStatus::Passed
        );
        assert_eq!(artifact.groups.len(), 1);
        assert_eq!(artifact.groups[0].group_id, "g01");
        assert_eq!(artifact.groups[0].manifests.len(), 1);
        assert_eq!(artifact.groups[0].manifests[0].scope, ManifestScope::Group);
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
                helm_values: HelmValues::new(),
                restart_namespaces: vec![],
                skip_validation_orders: vec![],
                manifests: vec![ManifestRef {
                    manifest_id: "g01:01".to_string(),
                    scope: ManifestScope::Group,
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
