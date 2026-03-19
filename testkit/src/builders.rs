// Builder types for constructing test fixture markdown and JSON payloads.
// Each builder produces the exact format expected by the harness parsers,
// replacing inline YAML/JSON strings scattered across test files.
//
// Test utilities intentionally panic on setup failures - callers are #[test]
// functions where an expect() failure is the correct way to surface problems.

use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use harness::hooks::application::GuardContext;
use harness::hooks::hook_result::{Decision, HookResult};
use harness::hooks::payloads::{AskUserQuestionOption, AskUserQuestionPrompt, HookEnvelopePayload};
use harness::run::workflow as runner_workflow;
use harness::run::{RunCounts, RunStatus, Verdict};
use harness::run::{RunLayout, RunMetadata};
use jsonschema::{Registry, Resource, Validator, options as jsonschema_options};
use serde_json::{Number as JsonNumber, Value as JsonValue};

// ---------------------------------------------------------------------------
// SuiteBuilder
// ---------------------------------------------------------------------------

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
        self.profiles = profiles.iter().map(|s| (*s).to_string()).collect();
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
        self.coverage_expectations = expectations.iter().map(|s| (*s).to_string()).collect();
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
        let mut s = String::from("---\n");
        push_field(&mut s, "suite_id", &self.suite_id);
        push_field(&mut s, "feature", &self.feature);
        push_field(&mut s, "scope", &self.scope);
        push_str_list(&mut s, "profiles", &self.profiles);
        push_str_list(&mut s, "requires", &self.requires);
        push_str_list(&mut s, "user_stories", &self.user_stories);
        push_str_list(&mut s, "variant_decisions", &self.variant_decisions);
        push_str_list(&mut s, "coverage_expectations", &self.coverage_expectations);
        push_str_list(&mut s, "baseline_files", &self.baseline_files);
        push_str_list(&mut s, "groups", &self.groups);
        push_str_list(&mut s, "skipped_groups", &self.skipped_groups);
        push_bool(&mut s, "keep_clusters", self.keep_clusters);
        s.push_str("---\n\n");
        s.push_str(&self.body);
        s
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

// ---------------------------------------------------------------------------
// GroupBuilder
// ---------------------------------------------------------------------------

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
        self.profiles = profiles.iter().map(|s| (*s).to_string()).collect();
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
    pub fn restart_namespace(mut self, ns: &str) -> Self {
        self.restart_namespaces.push(ns.to_string());
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
        let mut s = String::from("---\n");
        push_field(&mut s, "group_id", &self.group_id);
        push_field(&mut s, "story", &self.story);
        if let Some(ref cap) = self.capability {
            push_field(&mut s, "capability", cap);
        }
        push_str_list(&mut s, "profiles", &self.profiles);
        push_str_list(&mut s, "preconditions", &self.preconditions);
        push_str_list(&mut s, "success_criteria", &self.success_criteria);
        push_str_list(&mut s, "debug_checks", &self.debug_checks);
        push_str_list(&mut s, "artifacts", &self.artifacts);
        push_field(&mut s, "variant_source", &self.variant_source);

        // helm_values as inline mapping
        if self.helm_values.is_empty() {
            s.push_str("helm_values: {}\n");
        } else {
            s.push_str("helm_values:\n");
            let mut keys: Vec<&String> = self.helm_values.keys().collect();
            keys.sort();
            for key in keys {
                let value = &self.helm_values[key];
                let _ = writeln!(s, "  {key}: {value}");
            }
        }

        if self.restart_namespaces.is_empty() {
            s.push_str("restart_namespaces: []\n");
        } else {
            s.push_str("restart_namespaces:\n");
            for ns in &self.restart_namespaces {
                let _ = writeln!(s, "  - {ns}");
            }
        }

        if !self.expected_rejection_orders.is_empty() {
            let orders: Vec<String> = self
                .expected_rejection_orders
                .iter()
                .map(ToString::to_string)
                .collect();
            let _ = writeln!(s, "expected_rejection_orders: [{}]", orders.join(", "));
        }

        s.push_str("---\n\n");
        s.push_str("## Configure\n\n");
        s.push_str(&self.configure_section);
        s.push_str("\n\n## Consume\n\n");
        s.push_str(&self.consume_section);
        s.push_str("\n\n## Debug\n\n");
        s.push_str(&self.debug_section);
        s.push('\n');
        s
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

// ---------------------------------------------------------------------------
// MeshMetricGroupBuilder
// ---------------------------------------------------------------------------

/// Builds a `MeshMetric` group with `OpenTelemetry` backend config.
pub struct MeshMetricGroupBuilder {
    invalid_backend_ref: bool,
}

impl MeshMetricGroupBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self {
            invalid_backend_ref: false,
        }
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

impl Default for MeshMetricGroupBuilder {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// PolicyGroupBuilder
// ---------------------------------------------------------------------------

/// Selects which schema source to use for policy generation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PolicySchemaTarget {
    /// Use `OpenAPI` schemas (universal resources).
    Universal,
    /// Use Kubernetes CRD schemas.
    Kubernetes,
}

/// Builds a policy group using schema-driven minimal specs.
pub struct PolicyGroupBuilder {
    group_id: String,
    story: String,
    capability: Option<String>,
    profiles: Vec<String>,
    success_criteria: Vec<String>,
    debug_checks: Vec<String>,
    variant_source: String,
    helm_values: HashMap<String, String>,
    restart_namespaces: Vec<String>,
    expected_rejection_orders: Vec<i64>,
    consume_section: String,
    debug_section: String,

    kind: String,
    api_version: String,
    name: String,
    namespace: Option<String>,
    mesh: Option<String>,
    labels: BTreeMap<String, String>,
    target: PolicySchemaTarget,
    spec_override: Option<JsonValue>,
}

impl PolicyGroupBuilder {
    #[must_use]
    pub fn new(group_id: &str, kind: &str) -> Self {
        Self {
            group_id: group_id.to_string(),
            story: String::new(),
            capability: None,
            profiles: vec![],
            success_criteria: vec![],
            debug_checks: vec![],
            variant_source: "base".to_string(),
            helm_values: HashMap::new(),
            restart_namespaces: vec![],
            expected_rejection_orders: vec![],
            consume_section: "- Nothing to execute.".to_string(),
            debug_section: "- Nothing to inspect.".to_string(),

            kind: kind.to_string(),
            api_version: "kuma.io/v1alpha1".to_string(),
            name: "example-policy".to_string(),
            namespace: None,
            mesh: Some("default".to_string()),
            labels: BTreeMap::new(),
            target: PolicySchemaTarget::Universal,
            spec_override: None,
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
        self.profiles = profiles.iter().map(|s| (*s).to_string()).collect();
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
    pub fn restart_namespace(mut self, ns: &str) -> Self {
        self.restart_namespaces.push(ns.to_string());
        self
    }

    #[must_use]
    pub fn expected_rejection_orders(mut self, orders: &[i64]) -> Self {
        self.expected_rejection_orders = orders.to_vec();
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
    pub fn api_version(mut self, api_version: &str) -> Self {
        self.api_version = api_version.to_string();
        self
    }

    #[must_use]
    pub fn name(mut self, name: &str) -> Self {
        self.name = name.to_string();
        self
    }

    #[must_use]
    pub fn namespace(mut self, namespace: &str) -> Self {
        self.namespace = Some(namespace.to_string());
        self
    }

    #[must_use]
    pub fn mesh(mut self, mesh: &str) -> Self {
        self.mesh = Some(mesh.to_string());
        self
    }

    #[must_use]
    pub fn label(mut self, key: &str, value: &str) -> Self {
        self.labels.insert(key.to_string(), value.to_string());
        self
    }

    #[must_use]
    pub fn target(mut self, target: PolicySchemaTarget) -> Self {
        self.target = target;
        self
    }

    #[must_use]
    pub fn kubernetes(mut self) -> Self {
        self.target = PolicySchemaTarget::Kubernetes;
        self
    }

    #[must_use]
    pub fn universal(mut self) -> Self {
        self.target = PolicySchemaTarget::Universal;
        self
    }

    #[must_use]
    pub fn spec_override_json(mut self, value: JsonValue) -> Self {
        self.spec_override = Some(value);
        self
    }

    /// Set the spec override from a YAML string.
    ///
    /// # Panics
    /// Panics if YAML parsing fails.
    #[must_use]
    pub fn spec_override_yaml(mut self, yaml: &str) -> Self {
        let value: JsonValue = serde_yml::from_str(yaml).expect("parse spec override yaml");
        self.spec_override = Some(value);
        self
    }

    #[must_use]
    pub fn build_markdown(&self) -> String {
        let configure_section = self.build_configure_section();
        let mut group = GroupBuilder::new(&self.group_id)
            .story(&self.story)
            .profiles(&self.profiles.iter().map(String::as_str).collect::<Vec<_>>())
            .variant_source(&self.variant_source)
            .consume_section(&self.consume_section)
            .debug_section(&self.debug_section)
            .configure_section(&configure_section);

        if let Some(ref cap) = self.capability {
            group = group.capability(cap);
        }
        for criteria in &self.success_criteria {
            group = group.success_criteria(criteria);
        }
        for check in &self.debug_checks {
            group = group.debug_check(check);
        }
        for (k, v) in &self.helm_values {
            group = group.helm_value(k, v);
        }
        for ns in &self.restart_namespaces {
            group = group.restart_namespace(ns);
        }
        if !self.expected_rejection_orders.is_empty() {
            group = group.expected_rejection_orders(&self.expected_rejection_orders);
        }

        group.build_markdown()
    }

    /// Write the policy group to a file.
    ///
    /// # Panics
    /// Panics if directory creation or file write fails.
    #[must_use]
    pub fn write_to(&self, path: &Path) -> PathBuf {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create group parent dirs");
        }
        fs::write(path, self.build_markdown()).expect("write policy group file");
        path.to_path_buf()
    }

    fn build_configure_section(&self) -> String {
        let resource = self.build_policy_resource();
        let yaml = serde_yml::to_string(&resource).expect("serialize policy yaml");
        format!("```yaml\n{yaml}```")
    }

    fn build_policy_resource(&self) -> JsonValue {
        let schema_store = schema_store();
        match self.target {
            PolicySchemaTarget::Universal => self.build_universal_policy(schema_store),
            PolicySchemaTarget::Kubernetes => self.build_kubernetes_policy(schema_store),
        }
    }

    fn build_universal_policy(&self, schema_store: &SchemaStore) -> JsonValue {
        let item_schema = schema_store
            .openapi_schema_for_kind(&self.kind)
            .unwrap_or_else(|| panic!("missing OpenAPI schema for {}", self.kind));
        let item_schema = resolve_schema(
            &item_schema.contents,
            schema_store.registry(),
            item_schema.base_uri.as_str(),
        );

        let spec_schema = schema_property(&item_schema.contents, "spec")
            .unwrap_or_else(|| panic!("missing spec schema for {}", self.kind));
        let mut spec = minimal_from_schema(
            spec_schema,
            schema_store.registry(),
            item_schema.base_uri.as_str(),
        );
        if let Some(ref override_value) = self.spec_override {
            spec = merge_json(spec, override_value.clone());
        }
        validate_generated_spec(
            spec_schema,
            schema_store.registry(),
            item_schema.base_uri.as_str(),
            &self.kind,
            self.target,
            &spec,
        );

        let mut obj = serde_json::Map::new();
        obj.insert("type".to_string(), JsonValue::String(self.kind.clone()));
        obj.insert("name".to_string(), JsonValue::String(self.name.clone()));
        if let Some(ref mesh) = self.mesh {
            obj.insert("mesh".to_string(), JsonValue::String(mesh.clone()));
        }
        if !self.labels.is_empty() {
            let mut labels = serde_json::Map::new();
            for (k, v) in &self.labels {
                labels.insert(k.clone(), JsonValue::String(v.clone()));
            }
            obj.insert("labels".to_string(), JsonValue::Object(labels));
        }
        obj.insert("spec".to_string(), spec);

        JsonValue::Object(obj)
    }

    fn build_kubernetes_policy(&self, schema_store: &SchemaStore) -> JsonValue {
        let resource_schema = schema_store
            .crd_schema_for_kind_and_version(&self.kind, &self.api_version)
            .unwrap_or_else(|| {
                panic!(
                    "missing CRD schema for {} with apiVersion {}",
                    self.kind, self.api_version
                )
            });
        let resource_schema = resolve_schema(
            &resource_schema.contents,
            schema_store.registry(),
            resource_schema.base_uri.as_str(),
        );

        let spec_schema = schema_property(&resource_schema.contents, "spec")
            .unwrap_or_else(|| panic!("missing spec schema for {}", self.kind));
        let mut spec = minimal_from_schema(
            spec_schema,
            schema_store.registry(),
            resource_schema.base_uri.as_str(),
        );
        if let Some(ref override_value) = self.spec_override {
            spec = merge_json(spec, override_value.clone());
        }
        validate_generated_spec(
            spec_schema,
            schema_store.registry(),
            resource_schema.base_uri.as_str(),
            &self.kind,
            self.target,
            &spec,
        );

        let mut metadata = serde_json::Map::new();
        metadata.insert("name".to_string(), JsonValue::String(self.name.clone()));
        if let Some(ref namespace) = self.namespace {
            metadata.insert(
                "namespace".to_string(),
                JsonValue::String(namespace.clone()),
            );
        }
        let mut labels = self.labels.clone();
        if let Some(ref mesh) = self.mesh {
            labels
                .entry("kuma.io/mesh".to_string())
                .or_insert(mesh.clone());
        }
        if !labels.is_empty() {
            let mut label_obj = serde_json::Map::new();
            for (k, v) in labels {
                label_obj.insert(k, JsonValue::String(v));
            }
            metadata.insert("labels".to_string(), JsonValue::Object(label_obj));
        }

        let mut obj = serde_json::Map::new();
        obj.insert(
            "apiVersion".to_string(),
            JsonValue::String(self.api_version.clone()),
        );
        obj.insert("kind".to_string(), JsonValue::String(self.kind.clone()));
        obj.insert("metadata".to_string(), JsonValue::Object(metadata));
        obj.insert("spec".to_string(), spec);

        JsonValue::Object(obj)
    }
}

struct SchemaDocument {
    uri: String,
    contents: JsonValue,
}

struct SchemaFragment {
    contents: JsonValue,
    base_uri: String,
}

struct SchemaStore {
    registry: Registry,
    openapi: SchemaDocument,
    crds: BTreeMap<String, SchemaDocument>,
}

impl SchemaStore {
    fn load() -> Self {
        let openapi_path =
            env::var(ENV_OPENAPI_PATH).unwrap_or_else(|_| DEFAULT_OPENAPI_PATH.into());
        let openapi_text = fs::read_to_string(&openapi_path)
            .unwrap_or_else(|_| panic!("read OpenAPI schema from {openapi_path}"));
        let openapi_contents: JsonValue =
            serde_yml::from_str(&openapi_text).expect("parse OpenAPI schema");
        let openapi = SchemaDocument {
            uri: OPENAPI_SCHEMA_URI.to_string(),
            contents: openapi_contents,
        };

        let crd_dir = env::var(ENV_CRD_DIR).unwrap_or_else(|_| DEFAULT_CRD_DIR.into());
        let mut crds = BTreeMap::new();
        let mut resources = vec![(
            openapi.uri.clone(),
            Resource::from_contents(openapi.contents.clone()),
        )];
        if let Ok(entries) = fs::read_dir(&crd_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                let is_yaml = path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| {
                        ext.eq_ignore_ascii_case("yaml") || ext.eq_ignore_ascii_case("yml")
                    });
                if !is_yaml {
                    continue;
                }

                let text = fs::read_to_string(&path)
                    .unwrap_or_else(|_| panic!("read CRD schema from {}", path.display()));
                let crd: JsonValue = serde_yml::from_str(&text).expect("parse CRD schema");
                let Some(kind) = crd.pointer("/spec/names/kind").and_then(JsonValue::as_str) else {
                    continue;
                };

                let uri = format!("urn:harness:kuma:crd:{}", kind.to_ascii_lowercase());
                resources.push((uri.clone(), Resource::from_contents(crd.clone())));
                crds.insert(kind.to_string(), SchemaDocument { uri, contents: crd });
            }
        }

        let registry = Registry::try_from_resources(resources).expect("build schema registry");

        Self {
            registry,
            openapi,
            crds,
        }
    }

    fn registry(&self) -> &Registry {
        &self.registry
    }

    fn openapi_schema_for_kind(&self, kind: &str) -> Option<SchemaFragment> {
        let candidate = format!("/components/schemas/{kind}Item");
        let contents = self
            .openapi
            .contents
            .pointer(&candidate)
            .cloned()
            .or_else(|| {
                self.openapi
                    .contents
                    .pointer(&format!("/components/schemas/{kind}"))
                    .cloned()
            })?;
        Some(SchemaFragment {
            contents,
            base_uri: self.openapi.uri.clone(),
        })
    }

    fn crd_schema_for_kind_and_version(
        &self,
        kind: &str,
        api_version: &str,
    ) -> Option<SchemaFragment> {
        let crd = self.crds.get(kind)?;
        let (api_group, version_name) = match api_version.split_once('/') {
            Some((group, version)) => (Some(group), version),
            None => (None, api_version),
        };
        if let Some(group) = api_group
            && crd
                .contents
                .pointer("/spec/group")
                .and_then(JsonValue::as_str)
                != Some(group)
        {
            return None;
        }

        let versions = crd.contents.pointer("/spec/versions")?.as_array()?;
        let version = versions.iter().find(|value| {
            value.get("name").and_then(JsonValue::as_str) == Some(version_name)
                && value.get("schema").is_some()
        })?;
        let contents = version.pointer("/schema/openAPIV3Schema")?.clone();

        Some(SchemaFragment {
            contents,
            base_uri: crd.uri.clone(),
        })
    }
}

const DEFAULT_OPENAPI_PATH: &str = "testkit/resources/kuma/openapi.yaml";
const DEFAULT_CRD_DIR: &str = "testkit/resources/kuma/crds";
const ENV_OPENAPI_PATH: &str = "KUMA_OPENAPI_PATH";
const ENV_CRD_DIR: &str = "KUMA_CRD_DIR";
const OPENAPI_SCHEMA_URI: &str = "urn:harness:kuma:openapi";

static SCHEMA_STORE: OnceLock<SchemaStore> = OnceLock::new();

fn schema_store() -> &'static SchemaStore {
    SCHEMA_STORE.get_or_init(SchemaStore::load)
}

fn schema_property<'a>(schema: &'a JsonValue, name: &str) -> Option<&'a JsonValue> {
    schema.pointer(&format!("/properties/{name}"))
}

fn merge_json(base: JsonValue, overlay: JsonValue) -> JsonValue {
    match (base, overlay) {
        (JsonValue::Object(mut left), JsonValue::Object(right)) => {
            for (k, v) in right {
                let merged = if let Some(existing) = left.remove(&k) {
                    merge_json(existing, v)
                } else {
                    v
                };
                left.insert(k, merged);
            }
            JsonValue::Object(left)
        }
        (_, overlay) => overlay,
    }
}

fn minimal_from_schema(schema: &JsonValue, registry: &Registry, base_uri: &str) -> JsonValue {
    minimal_from_schema_inner(schema, registry, base_uri, 0)
}

fn minimal_from_schema_inner(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
    depth: usize,
) -> JsonValue {
    if depth > 20 {
        return JsonValue::Null;
    }

    let resolved = resolve_schema(schema, registry, base_uri);
    let schema = &resolved.contents;
    let base_uri = resolved.base_uri.as_str();

    if let Some(default_value) = schema.get("default") {
        return default_value.clone();
    }
    if let Some(enum_values) = schema.get("enum").and_then(JsonValue::as_array)
        && let Some(first) = enum_values.first()
    {
        return first.clone();
    }
    if let Some(const_value) = schema.get("const") {
        return const_value.clone();
    }

    if let Some(all_of) = schema.get("allOf").and_then(JsonValue::as_array) {
        let mut merged = JsonValue::Object(serde_json::Map::new());
        for item in all_of {
            merged = merge_json(
                merged,
                minimal_from_schema_inner(item, registry, base_uri, depth + 1),
            );
        }
        return merged;
    }
    if let Some(one_of) = schema.get("oneOf").and_then(JsonValue::as_array) {
        return select_schema_variant(schema, one_of, registry, base_uri, depth);
    }
    if let Some(any_of) = schema.get("anyOf").and_then(JsonValue::as_array) {
        return select_schema_variant(schema, any_of, registry, base_uri, depth);
    }

    let schema_type = schema.get("type").and_then(JsonValue::as_str);
    if schema_type == Some("object") || schema.get("properties").is_some() {
        let mut obj = serde_json::Map::new();
        let required = schema
            .get("required")
            .and_then(JsonValue::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(JsonValue::as_str)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        for prop in required {
            if let Some(prop_schema) = schema.pointer(&format!("/properties/{prop}")) {
                let value = minimal_from_schema_inner(prop_schema, registry, base_uri, depth + 1);
                obj.insert(prop.to_string(), value);
            }
        }
        return JsonValue::Object(obj);
    }

    if schema_type == Some("array") {
        let count = schema
            .get("minItems")
            .and_then(JsonValue::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(0);
        if let Some(items) = schema.get("items") {
            let value = minimal_from_schema_inner(items, registry, base_uri, depth + 1);
            let mut array = Vec::with_capacity(count);
            for _ in 0..count {
                array.push(value.clone());
            }
            return JsonValue::Array(array);
        }
        return JsonValue::Array(vec![]);
    }

    match schema_type {
        Some("string") => JsonValue::String(minimal_string_value(schema)),
        Some("integer") => JsonValue::Number(minimal_integer_value(schema)),
        Some("number") => JsonValue::Number(minimal_number_value(schema)),
        Some("boolean") => JsonValue::Bool(true),
        _ => JsonValue::Null,
    }
}

fn select_schema_variant(
    schema: &JsonValue,
    variants: &[JsonValue],
    registry: &Registry,
    base_uri: &str,
    depth: usize,
) -> JsonValue {
    for variant in variants {
        let candidate = minimal_from_schema_inner(variant, registry, base_uri, depth + 1);
        if schema_accepts(schema, registry, base_uri, &candidate) {
            return candidate;
        }
    }

    variants.first().map_or(JsonValue::Null, |variant| {
        minimal_from_schema_inner(variant, registry, base_uri, depth + 1)
    })
}

fn minimal_string_value(schema: &JsonValue) -> String {
    let min_length = schema
        .get("minLength")
        .and_then(JsonValue::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .unwrap_or(0);
    if min_length > 7 {
        "x".repeat(min_length)
    } else {
        "example".to_string()
    }
}

fn minimal_integer_value(schema: &JsonValue) -> JsonNumber {
    if let Some(value) = schema.get("minimum").and_then(JsonValue::as_i64) {
        return value.into();
    }
    if let Some(value) = schema.get("exclusiveMinimum").and_then(JsonValue::as_i64) {
        return (value + 1).into();
    }
    if let Some(i) = schema
        .get("exclusiveMinimum")
        .and_then(JsonValue::as_f64)
        .and_then(|v| JsonNumber::from_f64(v.floor()))
        .and_then(|n| n.as_i64())
    {
        return (i + 1).into();
    }
    1.into()
}

fn minimal_number_value(schema: &JsonValue) -> JsonNumber {
    if let Some(value) = schema.get("minimum").and_then(JsonValue::as_f64) {
        return JsonNumber::from_f64(value).unwrap_or_else(|| 1.into());
    }
    if let Some(value) = schema.get("exclusiveMinimum").and_then(JsonValue::as_f64) {
        return JsonNumber::from_f64(value + 1.0).unwrap_or_else(|| 1.into());
    }
    1.into()
}

fn schema_accepts(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
    instance: &JsonValue,
) -> bool {
    try_compile_schema_validator(schema, registry, base_uri)
        .is_some_and(|validator| validator.is_valid(instance))
}

fn try_compile_schema_validator(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
) -> Option<Validator> {
    jsonschema_options()
        .with_base_uri(base_uri.to_string())
        .with_registry(registry.clone())
        .build(schema)
        .ok()
}

fn compile_schema_validator(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
    kind: &str,
    target: PolicySchemaTarget,
) -> Validator {
    jsonschema_options()
        .with_base_uri(base_uri.to_string())
        .with_registry(registry.clone())
        .build(schema)
        .unwrap_or_else(|error| {
            panic!("compile {target:?} schema validator for {kind} from {base_uri}: {error}")
        })
}

fn validate_generated_spec(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
    kind: &str,
    target: PolicySchemaTarget,
    instance: &JsonValue,
) {
    let validator = compile_schema_validator(schema, registry, base_uri, kind, target);
    if validator.validate(instance).is_ok() {
        return;
    }

    let details = validator
        .iter_errors(instance)
        .take(5)
        .map(|error| error.to_string())
        .collect::<Vec<_>>()
        .join("; ");
    panic!("generated {target:?} spec for {kind} failed validation: {details}");
}

fn resolve_schema(schema: &JsonValue, registry: &Registry, base_uri: &str) -> SchemaFragment {
    let Some(reference) = schema.get("$ref").and_then(JsonValue::as_str) else {
        return SchemaFragment {
            contents: schema.clone(),
            base_uri: base_uri.to_string(),
        };
    };

    let ref_resolver = registry
        .try_resolver(base_uri)
        .unwrap_or_else(|error| panic!("build schema resolver for {base_uri}: {error}"));
    let lookup_result = ref_resolver.lookup(reference).unwrap_or_else(|error| {
        panic!("resolve schema ref {reference} against {base_uri}: {error}")
    });

    SchemaFragment {
        contents: lookup_result.contents().clone(),
        base_uri: lookup_result.resolver().base_uri().as_str().to_string(),
    }
}

// ---------------------------------------------------------------------------
// RunDirBuilder
// ---------------------------------------------------------------------------

/// Sets up a complete run directory with metadata, status, and runner state.
pub struct RunDirBuilder {
    tmp_path: PathBuf,
    run_id: String,
    suite_id: String,
    profile: String,
    keep_clusters: bool,
    suite_builder: Option<SuiteBuilder>,
    group_builder: Option<GroupBuilder>,
}

impl RunDirBuilder {
    #[must_use]
    pub fn new(tmp_path: &Path, run_id: &str) -> Self {
        Self {
            tmp_path: tmp_path.to_path_buf(),
            run_id: run_id.to_string(),
            suite_id: "example.suite".to_string(),
            profile: "single-zone".to_string(),
            keep_clusters: false,
            suite_builder: None,
            group_builder: None,
        }
    }

    #[must_use]
    pub fn suite_id(mut self, id: &str) -> Self {
        self.suite_id = id.to_string();
        self
    }

    #[must_use]
    pub fn profile(mut self, profile: &str) -> Self {
        self.profile = profile.to_string();
        self
    }

    #[must_use]
    pub fn suite(mut self, suite: SuiteBuilder) -> Self {
        self.suite_builder = Some(suite);
        self
    }

    #[must_use]
    pub fn group(mut self, group: GroupBuilder) -> Self {
        self.group_builder = Some(group);
        self
    }

    /// Build the run directory, writing all files. Returns `(run_dir, suite_dir)`.
    ///
    /// # Panics
    /// Panics if directory creation or file write fails.
    #[must_use]
    pub fn build(&self) -> (PathBuf, PathBuf) {
        let suite_dir = self.tmp_path.join("suite");

        // Write suite
        if let Some(ref sb) = self.suite_builder {
            let _ = sb.write_to(&suite_dir.join("suite.md"));
        } else {
            let _ = default_suite().write_to(&suite_dir.join("suite.md"));
        }

        // Write group
        if let Some(ref gb) = self.group_builder {
            let _ = gb.write_to(&suite_dir.join("groups").join("g01.md"));
        } else {
            let _ = default_group().write_to(&suite_dir.join("groups").join("g01.md"));
        }

        let run_root = self.tmp_path.join("runs");
        let layout = RunLayout::new(run_root.to_string_lossy().to_string(), self.run_id.clone());
        layout.ensure_dirs().expect("create run dirs");

        let suite_path = suite_dir.join("suite.md");
        let metadata = RunMetadata {
            run_id: self.run_id.clone(),
            suite_id: self.suite_id.clone(),
            suite_path: suite_path.to_string_lossy().to_string(),
            suite_dir: suite_dir.to_string_lossy().to_string(),
            profile: self.profile.clone(),
            repo_root: self.tmp_path.to_string_lossy().to_string(),
            keep_clusters: self.keep_clusters,
            created_at: "2026-03-14T00:00:00Z".to_string(),
            user_stories: vec![],
            requires: vec![],
        };
        let meta_json = serde_json::to_string_pretty(&metadata).expect("serialize metadata");
        fs::write(layout.metadata_path(), format!("{meta_json}\n")).expect("write metadata");

        let status = RunStatus {
            run_id: self.run_id.clone(),
            suite_id: self.suite_id.clone(),
            profile: self.profile.clone(),
            started_at: "2026-03-14T00:00:00Z".to_string(),
            overall_verdict: Verdict::Pending,
            completed_at: None,
            counts: RunCounts::default(),
            executed_groups: vec![],
            skipped_groups: vec![],
            last_completed_group: None,
            last_state_capture: None,
            last_updated_utc: None,
            next_planned_group: None,
            notes: vec![],
        };
        let status_json = serde_json::to_string_pretty(&status).expect("serialize status");
        fs::write(layout.status_path(), format!("{status_json}\n")).expect("write status");

        runner_workflow::initialize_runner_state(&layout.run_dir())
            .expect("initialize runner state");

        (layout.run_dir(), suite_dir)
    }

    /// Build and return only the run directory path.
    #[must_use]
    pub fn build_run_dir(&self) -> PathBuf {
        self.build().0
    }
}

/// Default kubernetes run: single-zone profile with standard suite and group.
#[must_use]
pub fn default_kubernetes_run(tmp: &Path, run_id: &str) -> RunDirBuilder {
    RunDirBuilder::new(tmp, run_id)
        .profile("single-zone")
        .suite(default_suite())
        .group(default_group())
}

/// Default universal run: single-zone-universal profile with universal suite and group.
#[must_use]
pub fn default_universal_run(tmp: &Path, run_id: &str) -> RunDirBuilder {
    RunDirBuilder::new(tmp, run_id)
        .profile("single-zone-universal")
        .suite(default_universal_suite())
        .group(default_group())
}

// ---------------------------------------------------------------------------
// HookPayloadBuilder
// ---------------------------------------------------------------------------

/// Builds `HookEnvelopePayload` for hook tests.
pub struct HookPayloadBuilder {
    tool_name: Option<String>,
    command: Option<String>,
    file_path: Option<PathBuf>,
    writes: Vec<PathBuf>,
    questions: Vec<AskUserQuestionPrompt>,
    tool_response: Option<serde_json::Value>,
    last_assistant_message: Option<String>,
    stop_hook_active: bool,
}

impl HookPayloadBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self {
            tool_name: None,
            command: None,
            file_path: None,
            writes: vec![],
            questions: vec![],
            tool_response: None,
            last_assistant_message: None,
            stop_hook_active: false,
        }
    }

    #[must_use]
    pub fn command(mut self, cmd: &str) -> Self {
        self.tool_name = Some("Bash".to_string());
        self.command = Some(cmd.to_string());
        self
    }

    #[must_use]
    pub fn write_path(mut self, path: &str) -> Self {
        self.tool_name = Some("Write".to_string());
        self.file_path = Some(PathBuf::from(path));
        self
    }

    #[must_use]
    pub fn write_paths(mut self, paths: &[&str]) -> Self {
        self.tool_name = Some("Write".to_string());
        self.writes = paths.iter().map(|s| PathBuf::from(*s)).collect();
        self
    }

    #[must_use]
    pub fn question(mut self, question: &str, options: &[&str]) -> Self {
        self.tool_name = Some("AskUserQuestion".to_string());
        let prompt = AskUserQuestionPrompt {
            question: question.to_string(),
            header: Some("Approval".to_string()),
            options: options
                .iter()
                .map(|label| AskUserQuestionOption {
                    label: (*label).to_string(),
                    description: format!("Select {label}"),
                })
                .collect(),
            multi_select: false,
        };
        self.questions.push(prompt);
        self
    }

    /// Add a question with a pre-set answer to the payload.
    ///
    /// # Panics
    /// Panics if serialization of the question or answer fails.
    #[must_use]
    pub fn question_with_answer(mut self, question: &str, options: &[&str], answer: &str) -> Self {
        self.tool_name = Some("AskUserQuestion".to_string());
        let prompt = AskUserQuestionPrompt {
            question: question.to_string(),
            header: Some("Approval".to_string()),
            options: options
                .iter()
                .map(|label| AskUserQuestionOption {
                    label: (*label).to_string(),
                    description: format!("Select {label}"),
                })
                .collect(),
            multi_select: false,
        };
        self.tool_response = Some(serde_json::json!({
            "answers": [{"question": question, "answer": answer}],
        }));
        self.questions.push(prompt);
        self
    }

    #[must_use]
    pub fn stop_hook_active(mut self, active: bool) -> Self {
        self.stop_hook_active = active;
        self
    }

    #[must_use]
    pub fn last_assistant_message(mut self, msg: &str) -> Self {
        self.last_assistant_message = Some(msg.to_string());
        self
    }

    #[must_use]
    pub fn build_envelope(&self) -> HookEnvelopePayload {
        let tool_input = if let Some(command) = &self.command {
            serde_json::json!({ "command": command })
        } else if let Some(file_path) = &self.file_path {
            serde_json::json!({ "file_path": file_path })
        } else if !self.writes.is_empty() {
            let paths = self
                .writes
                .iter()
                .map(|path| path.to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            serde_json::json!({ "file_paths": paths })
        } else if !self.questions.is_empty() {
            serde_json::json!({ "questions": self.questions })
        } else {
            serde_json::Value::Null
        };

        HookEnvelopePayload {
            tool_name: self.tool_name.clone().unwrap_or_default(),
            tool_input,
            tool_response: self
                .tool_response
                .clone()
                .unwrap_or(serde_json::Value::Null),
            last_assistant_message: self.last_assistant_message.clone(),
            transcript_path: None,
            stop_hook_active: self.stop_hook_active,
            raw_keys: vec![],
        }
    }

    /// Build a `GuardContext` for a given skill.
    #[must_use]
    pub fn build_context(self, skill: &str) -> GuardContext {
        GuardContext::from_envelope(skill, self.build_envelope())
    }

    /// Build a `GuardContext` with an associated run directory.
    #[must_use]
    pub fn build_context_with_run(self, skill: &str, run_dir: &Path) -> GuardContext {
        use harness::run::RunContext;

        let envelope = self.build_envelope();
        let mut ctx = GuardContext::from_envelope(skill, envelope);
        ctx.run_dir = Some(run_dir.to_path_buf());
        if let Ok(run_ctx) = RunContext::from_run_dir(run_dir) {
            ctx.runner_state = runner_workflow::read_runner_state(&run_ctx.layout.run_dir())
                .ok()
                .flatten();
            ctx.run = Some(run_ctx);
        }
        ctx
    }
}

impl Default for HookPayloadBuilder {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Frontmatter helpers (simple YAML formatting)
// ---------------------------------------------------------------------------

/// Render a scalar field.
fn push_field(s: &mut String, key: &str, value: &str) {
    let _ = writeln!(s, "{key}: {value}");
}

/// Render a boolean field.
fn push_bool(s: &mut String, key: &str, value: bool) {
    let _ = writeln!(s, "{key}: {value}");
}

/// Render a list field. Empty lists use inline `[]` syntax.
fn push_str_list(s: &mut String, key: &str, values: &[String]) {
    if values.is_empty() {
        let _ = writeln!(s, "{key}: []");
    } else if values.len() <= 4 && values.iter().all(|v| !v.contains(',') && v.len() < 30) {
        let joined = values.join(", ");
        let _ = writeln!(s, "{key}: [{joined}]");
    } else {
        let _ = writeln!(s, "{key}:");
        for v in values {
            let _ = writeln!(s, "  - {v}");
        }
    }
}

// ---------------------------------------------------------------------------
// Convenience functions matching the old helpers.rs API
// ---------------------------------------------------------------------------

/// Write a default suite file. Drop-in replacement for `helpers::write_suite`.
pub fn write_suite(path: &Path) {
    let _ = default_suite().write_to(path);
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

/// Initialize a run directory. Drop-in replacement for `helpers::init_run`.
/// Returns the run directory path.
#[must_use]
pub fn init_run(tmp_path: &Path, run_id: &str, profile: &str) -> PathBuf {
    RunDirBuilder::new(tmp_path, run_id)
        .profile(profile)
        .build_run_dir()
}

/// Initialize a run and return `(run_dir, suite_dir)`.
/// Drop-in replacement for `helpers::init_run_with_suite`.
#[must_use]
pub fn init_run_with_suite(tmp_path: &Path, run_id: &str, profile: &str) -> (PathBuf, PathBuf) {
    RunDirBuilder::new(tmp_path, run_id)
        .profile(profile)
        .build()
}

/// Initialize a universal mode run directory.
#[must_use]
pub fn init_universal_run(tmp_path: &Path, run_id: &str) -> PathBuf {
    RunDirBuilder::new(tmp_path, run_id)
        .profile("single-zone-universal")
        .build_run_dir()
}

/// Initialize a universal mode run with suite.
#[must_use]
pub fn init_universal_run_with_suite(tmp_path: &Path, run_id: &str) -> (PathBuf, PathBuf) {
    RunDirBuilder::new(tmp_path, run_id)
        .profile("single-zone-universal")
        .build()
}

/// Build a bash hook envelope. Drop-in for `helpers::make_bash_payload`.
#[must_use]
pub fn make_bash_payload(command: &str) -> HookEnvelopePayload {
    HookPayloadBuilder::new().command(command).build_envelope()
}

/// Build a write hook envelope. Drop-in for `helpers::make_write_payload`.
#[must_use]
pub fn make_write_payload(file_path: &str) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .write_path(file_path)
        .build_envelope()
}

/// Build a multi-write hook envelope. Drop-in for `helpers::make_multi_write_payload`.
#[must_use]
pub fn make_multi_write_payload(paths: &[&str]) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .write_paths(paths)
        .build_envelope()
}

/// Build a stop hook envelope. Drop-in for `helpers::make_stop_payload`.
#[must_use]
pub fn make_stop_payload() -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .stop_hook_active(true)
        .build_envelope()
}

/// Build a question hook envelope. Drop-in for `helpers::make_question_payload`.
#[must_use]
pub fn make_question_payload(question: &str, options: &[&str]) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .question(question, options)
        .build_envelope()
}

/// Build a question-with-answer hook envelope.
/// Drop-in for `helpers::make_question_answer_payload`.
#[must_use]
pub fn make_question_answer_payload(
    question: &str,
    options: &[&str],
    answer: &str,
) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .question_with_answer(question, options, answer)
        .build_envelope()
}

/// Build an empty hook envelope. Drop-in for `helpers::make_empty_payload`.
#[must_use]
pub fn make_empty_payload() -> HookEnvelopePayload {
    HookPayloadBuilder::new().build_envelope()
}

/// Build a `GuardContext` for a given skill and envelope.
/// Drop-in for `helpers::make_hook_context`.
#[must_use]
pub fn make_hook_context(skill: &str, payload: HookEnvelopePayload) -> GuardContext {
    GuardContext::from_envelope(skill, payload)
}

/// Build a `GuardContext` with an associated run directory.
/// Drop-in for `helpers::make_hook_context_with_run`.
#[must_use]
pub fn make_hook_context_with_run(
    skill: &str,
    payload: HookEnvelopePayload,
    run_dir: &Path,
) -> GuardContext {
    use harness::run::RunContext;

    let mut ctx = GuardContext::from_envelope(skill, payload);
    ctx.run_dir = Some(run_dir.to_path_buf());
    if let Ok(run_ctx) = RunContext::from_run_dir(run_dir) {
        ctx.runner_state = runner_workflow::read_runner_state(&run_ctx.layout.run_dir())
            .ok()
            .flatten();
        ctx.run = Some(run_ctx);
    }
    ctx
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

/// Assert the hook result matches a specific decision.
///
/// # Panics
/// Panics if the decision does not match the expected value.
pub fn assert_decision(result: &HookResult, expected: &Decision) {
    assert_eq!(
        &result.decision, expected,
        "expected {expected:?}, got {:?} (code={}, message={})",
        result.decision, result.code, result.message
    );
}

/// Assert the hook result is Allow.
pub fn assert_allow(result: &HookResult) {
    assert_decision(result, &Decision::Allow);
}

/// Assert the hook result is Deny.
pub fn assert_deny(result: &HookResult) {
    assert_decision(result, &Decision::Deny);
}

/// Assert the hook result is Warn.
pub fn assert_warn(result: &HookResult) {
    assert_decision(result, &Decision::Warn);
}

// ---------------------------------------------------------------------------
// Run status helpers
// ---------------------------------------------------------------------------

/// Read a `RunStatus` from a run directory.
///
/// # Panics
/// Panics if reading or parsing `run-status.json` fails.
#[must_use]
pub fn read_run_status(run_dir: &Path) -> RunStatus {
    let path = run_dir.join("run-status.json");
    let text = fs::read_to_string(&path).expect("read run-status.json");
    serde_json::from_str(&text).expect("parse run-status.json")
}

/// Write a `RunStatus` to a run directory.
///
/// # Panics
/// Panics if serialization or file write fails.
pub fn write_run_status(run_dir: &Path, status: &RunStatus) {
    let path = run_dir.join("run-status.json");
    let json = serde_json::to_string_pretty(status).expect("serialize status");
    fs::write(&path, format!("{json}\n")).expect("write run-status.json");
}

/// Read runner workflow state from a run directory.
///
/// # Panics
/// Panics if reading the state file fails.
#[must_use]
pub fn read_runner_state(run_dir: &Path) -> Option<harness::run::workflow::RunnerWorkflowState> {
    runner_workflow::read_runner_state(run_dir).expect("read runner state")
}

// ---------------------------------------------------------------------------
// kubectl-validate helpers
// ---------------------------------------------------------------------------

/// Seed a minimal cluster.json in a run directory's state folder.
///
/// Creates the file that `RunServices::cluster_runtime()` loads, giving
/// the run a synthetic cluster context so that capture/apply commands work
/// without running `harness cluster`.
///
/// # Panics
/// Panics if directory creation or file write fails.
pub fn seed_cluster_state(run_dir: &Path, kubeconfig: &str) {
    let state_dir = run_dir.join("state");
    fs::create_dir_all(&state_dir).expect("create state dir");
    let payload = serde_json::json!({
        "mode": "single-up",
        "platform": "kubernetes",
        "members": [{
            "name": "kuma-test",
            "role": "primary",
            "kubeconfig": kubeconfig,
        }],
        "mode_args": ["kuma-test"],
        "helm_settings": [],
        "restart_namespaces": [],
        "repo_root": "/tmp",
    });
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&payload).unwrap(),
    )
    .expect("write cluster.json");
}

/// Seed kubectl-validate state for tests.
///
/// # Panics
/// Panics if directory creation or file write fails.
pub fn seed_kubectl_validate_state(
    xdg_data_home: &Path,
    decision: &str,
    binary_path: Option<&Path>,
) {
    let path = xdg_data_home
        .join("harness")
        .join("tooling")
        .join("kubectl-validate.json");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create tooling dir");
    }
    let mut payload = serde_json::json!({
        "schema_version": 1,
        "decision": decision,
        "decided_at": "2026-03-13T00:00:00Z",
    });
    if let Some(bp) = binary_path {
        payload["binary_path"] = serde_json::Value::String(bp.to_string_lossy().to_string());
    }
    fs::write(&path, serde_json::to_string(&payload).unwrap())
        .expect("write kubectl-validate state");
}
