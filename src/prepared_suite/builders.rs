use std::borrow::Cow;
use std::fs;
use std::path::{Path, PathBuf};

use rayon::prelude::*;

use crate::context::RunLayout;
use crate::errors::{CliError, CliErrorKind};
use crate::io::ensure_dir;
use crate::schema::{GroupSpec, SuiteSpec};

use super::digest::{file_sha256, source_digest, text_sha256};
use super::extraction::{configure_section, yaml_blocks};
use super::manifest::{
    ManifestRef, ManifestScope, ManifestValidation, PreparedCopy, PreparedGroup, PreparedWrite,
    ValidationStatus,
};

#[derive(Debug, Default)]
pub(super) struct BaselinePlan {
    pub(super) source_digests: Vec<super::digest::SourceDigest>,
    pub(super) baselines: Vec<ManifestRef>,
    pub(super) baseline_copies: Vec<PreparedCopy>,
    pub(super) validation_writes: Vec<PreparedWrite>,
}

#[derive(Debug)]
pub(super) struct GroupPlan {
    pub(super) source_digest: super::digest::SourceDigest,
    pub(super) group: PreparedGroup,
    pub(super) group_writes: Vec<PreparedWrite>,
    pub(super) validation_writes: Vec<PreparedWrite>,
}

#[derive(Debug)]
pub(super) struct GroupManifestPlan {
    pub(super) refs: Vec<ManifestRef>,
    pub(super) group_writes: Vec<PreparedWrite>,
    pub(super) validation_writes: Vec<PreparedWrite>,
}

pub(super) fn build_baseline_plan(
    layout: &RunLayout,
    suite: &SuiteSpec,
) -> Result<BaselinePlan, CliError> {
    let suite_dir = suite.suite_dir();
    let run_dir = layout.run_dir();

    let results: Result<Vec<_>, CliError> = suite
        .frontmatter
        .baseline_files
        .par_iter()
        .map(|baseline| {
            let source_path = suite_dir.join(baseline.as_str());
            let prepared_rel = PathBuf::from("manifests")
                .join("prepared")
                .join("baseline")
                .join(baseline.as_str());
            let validation_rel = validation_path_for(&prepared_rel);
            let sd = source_digest(&source_path, baseline)?;
            let manifest_ref = build_baseline_manifest_ref(
                baseline,
                &source_path,
                &prepared_rel,
                &validation_rel,
            )?;
            let baseline_copy = PreparedCopy {
                source_path,
                prepared_path: run_dir.join(&prepared_rel),
            };
            let validation_write = PreparedWrite {
                prepared_path: run_dir.join(&validation_rel),
                text: Cow::Borrowed(pending_validation_text(false)),
            };
            Ok((sd, manifest_ref, baseline_copy, validation_write))
        })
        .collect();

    let mut plan = BaselinePlan::default();
    for (sd, manifest_ref, baseline_copy, validation_write) in results? {
        plan.source_digests.push(sd);
        plan.baselines.push(manifest_ref);
        plan.baseline_copies.push(baseline_copy);
        plan.validation_writes.push(validation_write);
    }

    Ok(plan)
}

pub(super) fn build_group_plan(
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

pub(super) fn copy_prepared_file(copy: &PreparedCopy) -> Result<(), CliError> {
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
