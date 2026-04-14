use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map as JsonMap, Value as JsonValue};

use super::group::GroupBuilder;
use super::schema::{
    SchemaStore, merge_json, minimal_from_schema, resolve_schema, schema_property, schema_store,
    validate_generated_spec,
};

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
        self.build_group(&configure_section).build_markdown()
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

    fn build_group(&self, configure_section: &str) -> GroupBuilder {
        let profiles = self.profiles.iter().map(String::as_str).collect::<Vec<_>>();
        let mut group = GroupBuilder::new(&self.group_id)
            .story(&self.story)
            .profiles(&profiles)
            .variant_source(&self.variant_source)
            .consume_section(&self.consume_section)
            .debug_section(&self.debug_section)
            .configure_section(configure_section);

        if let Some(capability) = &self.capability {
            group = group.capability(capability);
        }
        for criteria in &self.success_criteria {
            group = group.success_criteria(criteria);
        }
        for check in &self.debug_checks {
            group = group.debug_check(check);
        }
        for (key, value) in &self.helm_values {
            group = group.helm_value(key, value);
        }
        for namespace in &self.restart_namespaces {
            group = group.restart_namespace(namespace);
        }
        if !self.expected_rejection_orders.is_empty() {
            group = group.expected_rejection_orders(&self.expected_rejection_orders);
        }

        group
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
        if let Some(override_value) = &self.spec_override {
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

        let mut resource = JsonMap::new();
        resource.insert("type".to_string(), JsonValue::String(self.kind.clone()));
        resource.insert("name".to_string(), JsonValue::String(self.name.clone()));
        if let Some(mesh) = &self.mesh {
            resource.insert("mesh".to_string(), JsonValue::String(mesh.clone()));
        }
        if !self.labels.is_empty() {
            let mut labels = JsonMap::new();
            for (key, value) in &self.labels {
                labels.insert(key.clone(), JsonValue::String(value.clone()));
            }
            resource.insert("labels".to_string(), JsonValue::Object(labels));
        }
        resource.insert("spec".to_string(), spec);

        JsonValue::Object(resource)
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
        if let Some(override_value) = &self.spec_override {
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

        let mut metadata = JsonMap::new();
        metadata.insert("name".to_string(), JsonValue::String(self.name.clone()));
        if let Some(namespace) = &self.namespace {
            metadata.insert(
                "namespace".to_string(),
                JsonValue::String(namespace.clone()),
            );
        }
        let mut labels = self.labels.clone();
        if let Some(mesh) = &self.mesh {
            labels
                .entry("kuma.io/mesh".to_string())
                .or_insert(mesh.clone());
        }
        if !labels.is_empty() {
            let mut label_object = JsonMap::new();
            for (key, value) in labels {
                label_object.insert(key, JsonValue::String(value));
            }
            metadata.insert("labels".to_string(), JsonValue::Object(label_object));
        }

        let mut resource = JsonMap::new();
        resource.insert(
            "apiVersion".to_string(),
            JsonValue::String(self.api_version.clone()),
        );
        resource.insert("kind".to_string(), JsonValue::String(self.kind.clone()));
        resource.insert("metadata".to_string(), JsonValue::Object(metadata));
        resource.insert("spec".to_string(), spec);

        JsonValue::Object(resource)
    }
}
