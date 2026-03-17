use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::io;
use crate::rules;

use super::frontmatter::SuiteFrontmatter;
use super::parsers::{
    split_frontmatter, yaml_bool, yaml_helm_values, yaml_int_list, yaml_str, yaml_str_list,
};

/// A loaded suite specification with its source path.
#[derive(Debug, Clone)]
pub struct SuiteSpec {
    pub frontmatter: SuiteFrontmatter,
    pub path: PathBuf,
}

impl SuiteSpec {
    /// Load a suite spec from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing or frontmatter is invalid.
    pub fn from_markdown(path: &Path) -> Result<Self, CliError> {
        let text = io::read_text(path)?;
        let (yaml, _body) = split_frontmatter(&text)?;
        let map = &yaml;

        let suite_id = yaml_str(map, "suite_id");
        let feature = yaml_str(map, "feature");

        // Require both suite_id and feature
        let mut missing = Vec::new();
        if suite_id.is_none() {
            missing.push("suite_id");
        }
        if feature.is_none() {
            missing.push("feature");
        }
        if yaml_str(map, "scope").is_none()
            && !map.contains_key(serde_yml::Value::String("scope".to_string()))
        {
            missing.push("scope");
        }
        if !map.contains_key(serde_yml::Value::String("keep_clusters".to_string())) {
            missing.push("keep_clusters");
        }
        if !missing.is_empty() {
            return Err(
                CliErrorKind::missing_fields("suite frontmatter", missing.join(", ")).into(),
            );
        }

        let frontmatter = SuiteFrontmatter {
            suite_id: suite_id.unwrap_or_default(),
            feature: feature.unwrap_or_default(),
            scope: yaml_str(map, "scope"),
            profiles: yaml_str_list(map, "profiles"),
            required_dependencies: yaml_str_list(map, "required_dependencies"),
            user_stories: yaml_str_list(map, "user_stories"),
            variant_decisions: yaml_str_list(map, "variant_decisions"),
            coverage_expectations: yaml_str_list(map, "coverage_expectations"),
            baseline_files: yaml_str_list(map, "baseline_files"),
            groups: yaml_str_list(map, "groups"),
            skipped_groups: yaml_str_list(map, "skipped_groups"),
            keep_clusters: yaml_bool(map, "keep_clusters"),
        };

        Ok(Self {
            frontmatter,
            path: path.to_path_buf(),
        })
    }

    #[must_use]
    pub fn suite_dir(&self) -> &Path {
        self.path.parent().unwrap_or(Path::new("."))
    }
}

/// Group frontmatter payload from a group markdown file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GroupFrontmatter {
    pub group_id: String,
    pub story: String,
    #[serde(default)]
    pub capability: Option<String>,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub preconditions: Vec<String>,
    #[serde(default)]
    pub success_criteria: Vec<String>,
    #[serde(default)]
    pub debug_checks: Vec<String>,
    #[serde(default)]
    pub artifacts: Vec<String>,
    #[serde(default)]
    pub variant_source: Option<String>,
    #[serde(default)]
    pub helm_values: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub restart_namespaces: Vec<String>,
    #[serde(default)]
    pub expected_rejection_orders: Vec<i64>,
}

/// A loaded group specification with path and body.
#[derive(Debug, Clone)]
pub struct GroupSpec {
    pub frontmatter: GroupFrontmatter,
    pub path: PathBuf,
    pub body: String,
}

impl GroupSpec {
    /// Load a group spec from a markdown file.
    ///
    /// # Errors
    /// Returns `CliError` if the file is missing, frontmatter is invalid,
    /// or required sections are missing.
    pub fn from_markdown(path: &Path) -> Result<Self, CliError> {
        let text = io::read_text(path)?;
        let (yaml, body) = split_frontmatter(&text)?;
        let map = &yaml;

        // Check required sections in body
        let missing = rules::shared::GroupSection::missing_from(&body);
        if !missing.is_empty() {
            let labels: Vec<&str> = missing.iter().map(|s| s.as_str()).collect();
            return Err(CliErrorKind::missing_sections("group body", labels.join(", ")).into());
        }

        let frontmatter = GroupFrontmatter {
            group_id: yaml_str(map, "group_id").unwrap_or_default(),
            story: yaml_str(map, "story").unwrap_or_default(),
            capability: yaml_str(map, "capability"),
            profiles: yaml_str_list(map, "profiles"),
            preconditions: yaml_str_list(map, "preconditions"),
            success_criteria: yaml_str_list(map, "success_criteria"),
            debug_checks: yaml_str_list(map, "debug_checks"),
            artifacts: yaml_str_list(map, "artifacts"),
            variant_source: yaml_str(map, "variant_source"),
            helm_values: yaml_helm_values(map, "helm_values"),
            restart_namespaces: yaml_str_list(map, "restart_namespaces"),
            expected_rejection_orders: yaml_int_list(map, "expected_rejection_orders"),
        };

        Ok(Self {
            frontmatter,
            path: path.to_path_buf(),
            body,
        })
    }
}
