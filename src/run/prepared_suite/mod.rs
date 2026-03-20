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
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::run::SuiteSpec;
use crate::run::context::RunLayout;

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
mod tests;
