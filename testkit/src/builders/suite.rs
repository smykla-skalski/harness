use std::fs;
use std::path::{Path, PathBuf};

use super::frontmatter::{push_bool, push_field, push_str_list};

/// Builds a suite markdown file with YAML frontmatter.
pub struct SuiteBuilder {
    suite_id: String,
    feature: String,
    scope: String,
    profiles: Vec<String>,
    requires: Vec<String>,
    user_stories: Vec<String>,
    variant_decisions: Vec<String>,
    coverage_expectations: Vec<String>,
    baseline_files: Vec<String>,
    groups: Vec<String>,
    skipped_groups: Vec<String>,
    keep_clusters: bool,
    body: String,
}

impl SuiteBuilder {
    #[must_use]
    pub fn new(suite_id: &str) -> Self {
        Self {
            suite_id: suite_id.to_string(),
            feature: String::new(),
            scope: "unit".to_string(),
            profiles: vec![],
            requires: vec![],
            user_stories: vec![],
            variant_decisions: vec![],
            coverage_expectations: vec!["configure".into(), "consume".into(), "debug".into()],
            baseline_files: vec![],
            groups: vec![],
            skipped_groups: vec![],
            keep_clusters: false,
            body: "# Test suite\n".to_string(),
        }
    }

    #[must_use]
    pub fn feature(mut self, feature: &str) -> Self {
        self.feature = feature.to_string();
        self
    }

    #[must_use]
    pub fn scope(mut self, scope: &str) -> Self {
        self.scope = scope.to_string();
        self
    }

    #[must_use]
    pub fn profile(mut self, profile: &str) -> Self {
        self.profiles.push(profile.to_string());
        self
    }

    #[must_use]
    pub fn profiles(mut self, profiles: &[&str]) -> Self {
        self.profiles = profiles
            .iter()
            .map(|profile| (*profile).to_string())
            .collect();
        self
    }

    #[must_use]
    pub fn require(mut self, requirement: &str) -> Self {
        self.requires.push(requirement.to_string());
        self
    }

    #[must_use]
    pub fn user_story(mut self, story: &str) -> Self {
        self.user_stories.push(story.to_string());
        self
    }

    #[must_use]
    pub fn coverage_expectations(mut self, expectations: &[&str]) -> Self {
        self.coverage_expectations = expectations
            .iter()
            .map(|expectation| (*expectation).to_string())
            .collect();
        self
    }

    #[must_use]
    pub fn group(mut self, group: &str) -> Self {
        self.groups.push(group.to_string());
        self
    }

    #[must_use]
    pub fn keep_clusters(mut self, keep: bool) -> Self {
        self.keep_clusters = keep;
        self
    }

    #[must_use]
    pub fn body(mut self, body: &str) -> Self {
        self.body = body.to_string();
        self
    }

    #[must_use]
    pub fn build_markdown(&self) -> String {
        let mut markdown = String::from("---\n");
        push_field(&mut markdown, "suite_id", &self.suite_id);
        push_field(&mut markdown, "feature", &self.feature);
        push_field(&mut markdown, "scope", &self.scope);
        push_str_list(&mut markdown, "profiles", &self.profiles);
        push_str_list(&mut markdown, "requires", &self.requires);
        push_str_list(&mut markdown, "user_stories", &self.user_stories);
        push_str_list(&mut markdown, "variant_decisions", &self.variant_decisions);
        push_str_list(
            &mut markdown,
            "coverage_expectations",
            &self.coverage_expectations,
        );
        push_str_list(&mut markdown, "baseline_files", &self.baseline_files);
        push_str_list(&mut markdown, "groups", &self.groups);
        push_str_list(&mut markdown, "skipped_groups", &self.skipped_groups);
        push_bool(&mut markdown, "keep_clusters", self.keep_clusters);
        markdown.push_str("---\n\n");
        markdown.push_str(&self.body);
        markdown
    }

    /// Write the suite markdown to a file, creating parent directories.
    /// Returns the path written.
    ///
    /// # Panics
    /// Panics if directory creation or file write fails.
    #[must_use]
    pub fn write_to(&self, path: &Path) -> PathBuf {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create suite parent dirs");
        }
        fs::write(path, self.build_markdown()).expect("write suite file");
        path.to_path_buf()
    }
}

/// Default suite: `example.suite` with one group `groups/g01.md`.
#[must_use]
pub fn default_suite() -> SuiteBuilder {
    SuiteBuilder::new("example.suite")
        .feature("example")
        .scope("unit")
        .profile("single-zone")
        .group("groups/g01.md")
        .keep_clusters(false)
}

/// Default universal suite: `example.universal.suite` with single-zone-universal profile.
#[must_use]
pub fn default_universal_suite() -> SuiteBuilder {
    SuiteBuilder::new("example.universal.suite")
        .feature("example-universal")
        .scope("unit")
        .profile("single-zone-universal")
        .group("groups/g01.md")
        .keep_clusters(false)
}

/// Write a default suite file. Drop-in replacement for `helpers::write_suite`.
pub fn write_suite(path: &Path) {
    let _ = default_suite().write_to(path);
}
