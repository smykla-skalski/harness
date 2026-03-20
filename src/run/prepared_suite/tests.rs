use super::*;
use std::fs;

fn full_artifact_json() -> serde_json::Value {
    serde_json::json!({
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
    })
}

fn assert_full_artifact_sources(artifact: &PreparedSuiteArtifact) {
    assert_eq!(artifact.source_digests.len(), 1);
    assert_eq!(artifact.source_digests[0].digest, "suite-sha");
}

fn assert_full_artifact_baseline(artifact: &PreparedSuiteArtifact) {
    assert_eq!(artifact.baselines.len(), 1);
    assert_eq!(artifact.baselines[0].scope, ManifestScope::Baseline);
    assert_eq!(
        artifact.baselines[0].validation.as_ref().unwrap().status,
        ValidationStatus::Passed
    );
}

fn assert_full_artifact_group(artifact: &PreparedSuiteArtifact) {
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
    let body = "## Configure\nyaml stuff\n## Consume\nkubectl apply -f 01.yaml\n## Debug\ncheck\n";
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
            prepared_path: Some("manifests/prepared/baseline/baseline/namespace.yaml".to_string()),
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
                    output_path: Some("manifests/prepared/groups/g01/01.validate.txt".to_string()),
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
    let json = full_artifact_json();
    fs::write(&path, serde_json::to_string_pretty(&json).unwrap()).unwrap();

    let artifact = PreparedSuiteArtifact::load(&path).unwrap().unwrap();
    assert_full_artifact_sources(&artifact);
    assert_full_artifact_baseline(&artifact);
    assert_full_artifact_group(&artifact);
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
