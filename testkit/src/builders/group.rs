use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use super::frontmatter::{push_field, push_str_list};

/// Builds a group markdown file with YAML frontmatter and required sections.
pub struct GroupBuilder {
    group_id: String,
    story: String,
    capability: Option<String>,
    profiles: Vec<String>,
    preconditions: Vec<String>,
    success_criteria: Vec<String>,
    debug_checks: Vec<String>,
    artifacts: Vec<String>,
    variant_source: String,
    helm_values: HashMap<String, String>,
    restart_namespaces: Vec<String>,
    expected_rejection_orders: Vec<i64>,
    configure_section: String,
    consume_section: String,
    debug_section: String,
}

impl GroupBuilder {
    #[must_use]
    pub fn new(group_id: &str) -> Self {
        Self {
            group_id: group_id.to_string(),
            story: String::new(),
            capability: None,
            profiles: vec![],
            preconditions: vec![],
            success_criteria: vec![],
            debug_checks: vec![],
            artifacts: vec![],
            variant_source: "base".to_string(),
            helm_values: HashMap::new(),
            restart_namespaces: vec![],
            expected_rejection_orders: vec![],
            configure_section: "```yaml\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  \
                                name: example\n```"
                .to_string(),
            consume_section: "- Nothing to execute.".to_string(),
            debug_section: "- Nothing to inspect.".to_string(),
        }
    }

    #[must_use]
    pub fn story(mut self, story: &str) -> Self {
        self.story = story.to_string();
        self
    }

    #[must_use]
    pub fn capability(mut self, capability: &str) -> Self {
        self.capability = Some(capability.to_string());
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
    pub fn success_criteria(mut self, criteria: &str) -> Self {
        self.success_criteria.push(criteria.to_string());
        self
    }

    #[must_use]
    pub fn debug_check(mut self, check: &str) -> Self {
        self.debug_checks.push(check.to_string());
        self
    }

    #[must_use]
    pub fn variant_source(mut self, source: &str) -> Self {
        self.variant_source = source.to_string();
        self
    }

    #[must_use]
    pub fn helm_value(mut self, key: &str, value: &str) -> Self {
        self.helm_values.insert(key.to_string(), value.to_string());
        self
    }

    #[must_use]
    pub fn restart_namespace(mut self, namespace: &str) -> Self {
        self.restart_namespaces.push(namespace.to_string());
        self
    }

    #[must_use]
    pub fn expected_rejection_orders(mut self, orders: &[i64]) -> Self {
        self.expected_rejection_orders = orders.to_vec();
        self
    }

    #[must_use]
    pub fn configure_section(mut self, content: &str) -> Self {
        self.configure_section = content.to_string();
        self
    }

    #[must_use]
    pub fn consume_section(mut self, content: &str) -> Self {
        self.consume_section = content.to_string();
        self
    }

    #[must_use]
    pub fn debug_section(mut self, content: &str) -> Self {
        self.debug_section = content.to_string();
        self
    }

    #[must_use]
    pub fn build_markdown(&self) -> String {
        let mut markdown = String::from("---\n");
        push_field(&mut markdown, "group_id", &self.group_id);
        push_field(&mut markdown, "story", &self.story);
        if let Some(capability) = &self.capability {
            push_field(&mut markdown, "capability", capability);
        }
        push_str_list(&mut markdown, "profiles", &self.profiles);
        push_str_list(&mut markdown, "preconditions", &self.preconditions);
        push_str_list(&mut markdown, "success_criteria", &self.success_criteria);
        push_str_list(&mut markdown, "debug_checks", &self.debug_checks);
        push_str_list(&mut markdown, "artifacts", &self.artifacts);
        push_field(&mut markdown, "variant_source", &self.variant_source);

        if self.helm_values.is_empty() {
            markdown.push_str("helm_values: {}\n");
        } else {
            markdown.push_str("helm_values:\n");
            let mut keys: Vec<&String> = self.helm_values.keys().collect();
            keys.sort();
            for key in keys {
                let value = &self.helm_values[key];
                let _ = writeln!(markdown, "  {key}: {value}");
            }
        }

        if self.restart_namespaces.is_empty() {
            markdown.push_str("restart_namespaces: []\n");
        } else {
            markdown.push_str("restart_namespaces:\n");
            for namespace in &self.restart_namespaces {
                let _ = writeln!(markdown, "  - {namespace}");
            }
        }

        if !self.expected_rejection_orders.is_empty() {
            let orders = self
                .expected_rejection_orders
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>();
            let _ = writeln!(
                markdown,
                "expected_rejection_orders: [{}]",
                orders.join(", ")
            );
        }

        markdown.push_str("---\n\n");
        markdown.push_str("## Configure\n\n");
        markdown.push_str(&self.configure_section);
        markdown.push_str("\n\n## Consume\n\n");
        markdown.push_str(&self.consume_section);
        markdown.push_str("\n\n## Debug\n\n");
        markdown.push_str(&self.debug_section);
        markdown.push('\n');
        markdown
    }

    /// Write the group markdown to a file, creating parent directories.
    ///
    /// # Panics
    /// Panics if directory creation or file write fails.
    #[must_use]
    pub fn write_to(&self, path: &Path) -> PathBuf {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create group parent dirs");
        }
        fs::write(path, self.build_markdown()).expect("write group file");
        path.to_path_buf()
    }
}

/// Default group: `g01` with example story, single-zone profile.
#[must_use]
pub fn default_group() -> GroupBuilder {
    GroupBuilder::new("g01")
        .story("example story")
        .capability("example capability")
        .profile("single-zone")
}

/// Builds a `MeshMetric` group with `OpenTelemetry` backend config.
#[derive(Default)]
pub struct MeshMetricGroupBuilder {
    invalid_backend_ref: bool,
}

impl MeshMetricGroupBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn invalid_backend_ref(mut self, invalid: bool) -> Self {
        self.invalid_backend_ref = invalid;
        self
    }

    #[must_use]
    pub fn build_markdown(&self) -> String {
        let backend_ref = if self.invalid_backend_ref {
            "\
          backendRef:
            kind: MeshService
            name: otel-collector
"
        } else {
            ""
        };
        format!(
            "\
---
group_id: g01
story: meshmetric example story
capability: meshmetric example capability
profiles: [single-zone]
preconditions: []
success_criteria: []
debug_checks: []
artifacts: []
variant_source: base
helm_values: {{}}
restart_namespaces: []
---

## Configure

```yaml
apiVersion: kuma.io/v1alpha1
kind: MeshMetric
metadata:
  name: demo-metrics
  namespace: kuma-system
  labels:
    kuma.io/mesh: default
spec:
  targetRef:
    kind: Mesh
  default:
    backends:
      - type: OpenTelemetry
        openTelemetry:
          endpoint: otel-collector.observability.svc:4317
{backend_ref}```

## Consume

- Nothing to execute.

## Debug

- Nothing to inspect.
"
        )
    }

    /// Write the meshmetric group to a file.
    ///
    /// # Panics
    /// Panics if directory creation or file write fails.
    #[must_use]
    pub fn write_to(&self, path: &Path) -> PathBuf {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create group parent dirs");
        }
        fs::write(path, self.build_markdown()).expect("write meshmetric group file");
        path.to_path_buf()
    }
}

/// Write a default group file. Drop-in replacement for `helpers::write_group`.
pub fn write_group(path: &Path) {
    let _ = default_group().write_to(path);
}

/// Write a meshmetric group. Drop-in replacement for `helpers::write_meshmetric_group`.
pub fn write_meshmetric_group(path: &Path, invalid_backend_ref: bool) {
    let _ = MeshMetricGroupBuilder::new()
        .invalid_backend_ref(invalid_backend_ref)
        .write_to(path);
}
