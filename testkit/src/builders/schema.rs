use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::sync::OnceLock;

use jsonschema::{Registry, Resource, Validator, options as jsonschema_options, uri};
use serde_json::{Number as JsonNumber, Value as JsonValue};

use super::policy::PolicySchemaTarget;

pub(super) struct SchemaDocument {
    pub(super) uri: String,
    pub(super) contents: JsonValue,
}

pub(super) struct SchemaFragment {
    pub(super) contents: JsonValue,
    pub(super) base_uri: String,
}

pub(super) struct SchemaStore {
    registry: Registry<'static>,
    openapi: SchemaDocument,
    crds: BTreeMap<String, SchemaDocument>,
}

impl SchemaStore {
    pub(super) fn load() -> Self {
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
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| {
                        extension.eq_ignore_ascii_case("yaml")
                            || extension.eq_ignore_ascii_case("yml")
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

        let registry = Registry::new()
            .extend(resources)
            .expect("add schema resources to registry")
            .prepare()
            .expect("build schema registry");

        Self {
            registry,
            openapi,
            crds,
        }
    }

    pub(super) fn registry(&self) -> &Registry<'static> {
        &self.registry
    }

    pub(super) fn openapi_schema_for_kind(&self, kind: &str) -> Option<SchemaFragment> {
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

    pub(super) fn crd_schema_for_kind_and_version(
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
pub(super) const ENV_OPENAPI_PATH: &str = "KUMA_OPENAPI_PATH";
pub(super) const ENV_CRD_DIR: &str = "KUMA_CRD_DIR";
const OPENAPI_SCHEMA_URI: &str = "urn:harness:kuma:openapi";

static SCHEMA_STORE: OnceLock<SchemaStore> = OnceLock::new();

pub(super) fn schema_store() -> &'static SchemaStore {
    SCHEMA_STORE.get_or_init(SchemaStore::load)
}

pub(super) fn schema_property<'a>(schema: &'a JsonValue, name: &str) -> Option<&'a JsonValue> {
    schema.pointer(&format!("/properties/{name}"))
}

pub(super) fn merge_json(base: JsonValue, overlay: JsonValue) -> JsonValue {
    match (base, overlay) {
        (JsonValue::Object(mut left), JsonValue::Object(right)) => {
            for (key, value) in right {
                let merged = if let Some(existing) = left.remove(&key) {
                    merge_json(existing, value)
                } else {
                    value
                };
                left.insert(key, merged);
            }
            JsonValue::Object(left)
        }
        (_, overlay) => overlay,
    }
}

pub(super) fn minimal_from_schema(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
) -> JsonValue {
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
        let mut object = serde_json::Map::new();
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
        for property in required {
            if let Some(property_schema) = schema.pointer(&format!("/properties/{property}")) {
                let value =
                    minimal_from_schema_inner(property_schema, registry, base_uri, depth + 1);
                object.insert(property.to_string(), value);
            }
        }
        return JsonValue::Object(object);
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
    if let Some(integer) = schema
        .get("exclusiveMinimum")
        .and_then(JsonValue::as_f64)
        .and_then(|value| JsonNumber::from_f64(value.floor()))
        .and_then(|number| number.as_i64())
    {
        return (integer + 1).into();
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

fn try_compile_schema_validator<'a>(
    schema: &'a JsonValue,
    registry: &'a Registry<'a>,
    base_uri: &str,
) -> Option<Validator> {
    jsonschema_options()
        .with_base_uri(base_uri.to_string())
        .with_registry(registry)
        .build(schema)
        .ok()
}

fn compile_schema_validator<'a>(
    schema: &'a JsonValue,
    registry: &'a Registry<'a>,
    base_uri: &str,
    kind: &str,
    target: PolicySchemaTarget,
) -> Validator {
    jsonschema_options()
        .with_base_uri(base_uri.to_string())
        .with_registry(registry)
        .build(schema)
        .unwrap_or_else(|error| {
            panic!("compile {target:?} schema validator for {kind} from {base_uri}: {error}")
        })
}

pub(super) fn validate_generated_spec(
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

pub(super) fn resolve_schema(
    schema: &JsonValue,
    registry: &Registry,
    base_uri: &str,
) -> SchemaFragment {
    let Some(reference) = schema.get("$ref").and_then(JsonValue::as_str) else {
        return SchemaFragment {
            contents: schema.clone(),
            base_uri: base_uri.to_string(),
        };
    };

    let parsed_uri = uri::from_str(base_uri)
        .unwrap_or_else(|error| panic!("parse base URI {base_uri}: {error}"));
    let ref_resolver = registry.resolver(parsed_uri);
    let lookup_result = ref_resolver.lookup(reference).unwrap_or_else(|error| {
        panic!("resolve schema ref {reference} against {base_uri}: {error}")
    });

    SchemaFragment {
        contents: lookup_result.contents().clone(),
        base_uri: lookup_result.resolver().base_uri().as_str().to_string(),
    }
}
