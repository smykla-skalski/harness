use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::context::RunLayout;
use crate::errors::{CliError, CliErrorKind};
use crate::io::{ensure_dir, read_json_typed, write_json_pretty, write_text};
use crate::schema::{GroupSpec, SuiteSpec};

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
    pub text: Cow<'static, str>,
}

/// SHA256 digest of a source file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceDigest {
    pub source_path: String,
    pub digest: String,
}

/// Status of a manifest validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ValidationStatus {
    Pending,
    Passed,
    Failed,
}

impl fmt::Display for ValidationStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pending => f.write_str("pending"),
            Self::Passed => f.write_str("passed"),
            Self::Failed => f.write_str("failed"),
        }
    }
}

/// Validation result for a manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestValidation {
    #[serde(default)]
    pub output_path: Option<String>,
    pub status: ValidationStatus,
    #[serde(default)]
    pub checked_at: Option<String>,
    #[serde(default)]
    pub resource_kinds: Vec<String>,
}

/// Scope of a prepared manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ManifestScope {
    Baseline,
    Group,
}

pub type HelmValues = BTreeMap<String, serde_json::Value>;

/// Reference to a manifest in the prepared suite.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestRef {
    pub manifest_id: String,
    pub scope: ManifestScope,
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
    pub helm_values: HelmValues,
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

#[derive(Debug, Default)]
struct BaselinePlan {
    source_digests: Vec<SourceDigest>,
    baselines: Vec<ManifestRef>,
    baseline_copies: Vec<PreparedCopy>,
    validation_writes: Vec<PreparedWrite>,
}

#[derive(Debug)]
struct GroupPlan {
    source_digest: SourceDigest,
    group: PreparedGroup,
    group_writes: Vec<PreparedWrite>,
    validation_writes: Vec<PreparedWrite>,
}

#[derive(Debug)]
struct GroupManifestPlan {
    refs: Vec<ManifestRef>,
    group_writes: Vec<PreparedWrite>,
    validation_writes: Vec<PreparedWrite>,
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

        for group_rel in &suite.frontmatter.groups {
            let Some(group_plan) = build_group_plan(layout, suite, profile, group_rel)? else {
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

fn build_baseline_plan(layout: &RunLayout, suite: &SuiteSpec) -> Result<BaselinePlan, CliError> {
    let suite_dir = suite.suite_dir();
    let run_dir = layout.run_dir();
    let mut plan = BaselinePlan::default();

    for baseline in &suite.frontmatter.baseline_files {
        let source_path = suite_dir.join(baseline);
        let prepared_rel = PathBuf::from("manifests")
            .join("prepared")
            .join("baseline")
            .join(baseline);
        let validation_rel = validation_path_for(&prepared_rel);
        plan.source_digests
            .push(source_digest(&source_path, baseline)?);
        let manifest_ref =
            build_baseline_manifest_ref(baseline, &source_path, &prepared_rel, &validation_rel)?;
        plan.baseline_copies.push(PreparedCopy {
            source_path,
            prepared_path: run_dir.join(&prepared_rel),
        });
        plan.validation_writes.push(PreparedWrite {
            prepared_path: run_dir.join(&validation_rel),
            text: Cow::Borrowed(pending_validation_text(false)),
        });
        plan.baselines.push(manifest_ref);
    }

    Ok(plan)
}

fn build_group_plan(
    layout: &RunLayout,
    suite: &SuiteSpec,
    profile: &str,
    group_rel: &str,
) -> Result<Option<GroupPlan>, CliError> {
    let group_path = suite.suite_dir().join(group_rel);
    let group = GroupSpec::from_markdown(&group_path)?;
    if suite
        .frontmatter
        .skipped_groups
        .iter()
        .any(|item| item == group_rel || item == &group.frontmatter.group_id)
    {
        return Ok(None);
    }
    if !group.frontmatter.profiles.is_empty()
        && !group
            .frontmatter
            .profiles
            .iter()
            .any(|item| item == profile)
    {
        return Ok(None);
    }

    let manifests = build_group_manifests(layout, group_rel, &group)?;
    Ok(Some(GroupPlan {
        source_digest: source_digest(&group.path, group_rel)?,
        group: PreparedGroup {
            group_id: group.frontmatter.group_id,
            source_path: group_rel.to_string(),
            helm_values: group.frontmatter.helm_values.into_iter().collect(),
            restart_namespaces: group.frontmatter.restart_namespaces,
            skip_validation_orders: group.frontmatter.expected_rejection_orders,
            manifests: manifests.refs,
        },
        group_writes: manifests.group_writes,
        validation_writes: manifests.validation_writes,
    }))
}

fn build_group_manifests(
    layout: &RunLayout,
    group_rel: &str,
    group: &GroupSpec,
) -> Result<GroupManifestPlan, CliError> {
    let run_dir = layout.run_dir();
    let mut refs = Vec::new();
    let mut group_writes = Vec::new();
    let mut validation_writes = Vec::new();

    for (index, yaml) in yaml_blocks(configure_section(&group.body).unwrap_or_default())
        .into_iter()
        .enumerate()
    {
        let order = i64::try_from(index + 1).map_err(|error| {
            CliErrorKind::serialize(format!("group manifest order overflow: {error}"))
        })?;
        let prepared_rel = PathBuf::from("manifests")
            .join("prepared")
            .join("groups")
            .join(&group.frontmatter.group_id)
            .join(format!("{:02}.yaml", index + 1));
        let validation_rel = validation_path_for(&prepared_rel);
        let skip_validation = group.frontmatter.expected_rejection_orders.contains(&order);
        let manifest_ref = build_group_manifest_ref(
            group_rel,
            &group.frontmatter.group_id,
            index + 1,
            order,
            &yaml,
            &prepared_rel,
            &validation_rel,
        );
        group_writes.push(PreparedWrite {
            prepared_path: run_dir.join(&prepared_rel),
            text: Cow::Owned(yaml),
        });
        validation_writes.push(PreparedWrite {
            prepared_path: run_dir.join(&validation_rel),
            text: Cow::Borrowed(pending_validation_text(skip_validation)),
        });
        refs.push(manifest_ref);
    }

    Ok(GroupManifestPlan {
        refs,
        group_writes,
        validation_writes,
    })
}

fn build_baseline_manifest_ref(
    baseline: &str,
    source_path: &Path,
    prepared_rel: &Path,
    validation_rel: &Path,
) -> Result<ManifestRef, CliError> {
    Ok(ManifestRef {
        manifest_id: baseline.to_string(),
        scope: ManifestScope::Baseline,
        source_path: baseline.to_string(),
        validation: Some(ManifestValidation {
            output_path: Some(validation_rel.display().to_string()),
            status: ValidationStatus::Pending,
            checked_at: None,
            resource_kinds: vec![],
        }),
        group_id: None,
        prepared_path: Some(prepared_rel.display().to_string()),
        digest: Some(file_sha256(source_path)?),
        order: None,
        applied: false,
        applied_at: None,
        step: None,
        applied_path: None,
    })
}

fn build_group_manifest_ref(
    group_rel: &str,
    group_id: &str,
    manifest_number: usize,
    order: i64,
    yaml: &str,
    prepared_rel: &Path,
    validation_rel: &Path,
) -> ManifestRef {
    ManifestRef {
        manifest_id: format!("{group_id}:{manifest_number:02}"),
        scope: ManifestScope::Group,
        source_path: group_rel.to_string(),
        validation: Some(ManifestValidation {
            output_path: Some(validation_rel.display().to_string()),
            status: ValidationStatus::Pending,
            checked_at: None,
            resource_kinds: vec![],
        }),
        group_id: Some(group_id.to_string()),
        prepared_path: Some(prepared_rel.display().to_string()),
        digest: Some(text_sha256(yaml)),
        order: Some(order),
        applied: false,
        applied_at: None,
        step: None,
        applied_path: None,
    }
}

fn copy_prepared_file(copy: &PreparedCopy) -> Result<(), CliError> {
    let parent = copy
        .prepared_path
        .parent()
        .unwrap_or_else(|| Path::new("."));
    ensure_dir(parent)
        .map_err(|error| CliErrorKind::io(format!("create dir {}: {error}", parent.display())))?;
    fs::copy(&copy.source_path, &copy.prepared_path).map_err(|error| {
        CliErrorKind::io(format!(
            "copy {} -> {}: {error}",
            copy.source_path.display(),
            copy.prepared_path.display(),
        ))
    })?;
    Ok(())
}

fn source_digest(path: &Path, source_path: &str) -> Result<SourceDigest, CliError> {
    Ok(SourceDigest {
        source_path: source_path.to_string(),
        digest: file_sha256(path)?,
    })
}

fn file_sha256(path: &Path) -> Result<String, CliError> {
    let bytes = fs::read(path)
        .map_err(|error| CliErrorKind::io(format!("read {}: {error}", path.display())))?;
    let digest = Sha256::digest(&bytes);
    Ok(hex::encode(digest))
}

fn text_sha256(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}

fn validation_path_for(prepared_rel: &Path) -> PathBuf {
    let extension = prepared_rel
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("txt");
    prepared_rel.with_extension(format!("{extension}.validate.txt"))
}

fn pending_validation_text(skip_validation: bool) -> &'static str {
    if skip_validation {
        return "validation intentionally skipped by expected_rejection_orders\n";
    }
    "validation pending\n"
}

fn extract_section<'a>(body: &'a str, heading: &str) -> Option<&'a str> {
    let pattern = format!("## {heading}");
    let mut start = None;
    let mut offset = 0;

    for line in body.split_inclusive('\n') {
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
        if let Some(section_start) = start {
            if trimmed.starts_with("## ") {
                return Some(body[section_start..offset].trim_end_matches(['\n', '\r']));
            }
        } else if trimmed == pattern || trimmed.starts_with(&format!("{pattern} ")) {
            start = Some(offset + line.len());
        }
        offset += line.len();
    }

    start.map(|section_start| body[section_start..].trim_end_matches(['\n', '\r']))
}

/// Extract the Configure section from a group body.
#[must_use]
pub fn configure_section(body: &str) -> Option<&str> {
    extract_section(body, "Configure")
}

/// Extract the Consume section from a group body.
#[must_use]
pub fn consume_section(body: &str) -> Option<&str> {
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
                let joined = current_block.join("\n");
                let trimmed = joined.trim();
                if !trimmed.is_empty() {
                    blocks.push(format!("{trimmed}\n"));
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
