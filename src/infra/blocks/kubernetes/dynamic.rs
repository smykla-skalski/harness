use std::path::Path;

use fs_err as fs;
use kube::Client;
use kube::api::{Api, DynamicObject};
use kube::core::GroupVersionKind;
use kube::discovery::{self, ApiResource, Scope};
use serde::Deserialize;
use serde_json::Value;

use crate::infra::blocks::BlockError;
use crate::infra::exec::RUNTIME;

pub(crate) struct ManifestDocument {
    pub api_version: String,
    pub kind: String,
    pub name: String,
    pub namespace: Option<String>,
    pub value: Value,
}

pub(crate) struct ResolvedManifest {
    pub document: ManifestDocument,
    pub api_resource: ApiResource,
    pub scope: Scope,
    pub namespace: Option<String>,
}

impl ResolvedManifest {
    pub(crate) fn api(&self, client: Client) -> Api<DynamicObject> {
        match self.scope {
            Scope::Cluster => Api::all_with(client, &self.api_resource),
            Scope::Namespaced => Api::namespaced_with(
                client,
                self.namespace
                    .as_deref()
                    .expect("namespaced resource should have a namespace"),
                &self.api_resource,
            ),
        }
    }
}

pub(crate) fn manifest_documents_from_path(
    path: &Path,
) -> Result<Vec<ManifestDocument>, BlockError> {
    let text = fs::read_to_string(path)
        .map_err(|error| BlockError::new("kubernetes", "read manifest", error))?;

    let mut documents = Vec::new();
    for (index, document) in serde_yml::Deserializer::from_str(&text).enumerate() {
        let value: Value = Value::deserialize(document).map_err(|error| {
            BlockError::message(
                "kubernetes",
                "parse manifest",
                format!("document {}: {error}", index + 1),
            )
        })?;
        if value.is_null() {
            continue;
        }

        let api_version = value
            .get("apiVersion")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| {
                BlockError::message(
                    "kubernetes",
                    "parse manifest",
                    format!("document {}: missing apiVersion", index + 1),
                )
            })?;
        let kind = value
            .get("kind")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| {
                BlockError::message(
                    "kubernetes",
                    "parse manifest",
                    format!("document {}: missing kind", index + 1),
                )
            })?;
        let metadata = value
            .get("metadata")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                BlockError::message(
                    "kubernetes",
                    "parse manifest",
                    format!("document {}: missing metadata", index + 1),
                )
            })?;
        let name = metadata
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| {
                BlockError::message(
                    "kubernetes",
                    "parse manifest",
                    format!("document {}: missing metadata.name", index + 1),
                )
            })?;
        let namespace = metadata
            .get("namespace")
            .and_then(Value::as_str)
            .map(str::to_string);

        documents.push(ManifestDocument {
            api_version,
            kind,
            name,
            namespace,
            value,
        });
    }

    if documents.is_empty() {
        return Err(BlockError::message(
            "kubernetes",
            "parse manifest",
            format!("{} does not contain Kubernetes resources", path.display()),
        ));
    }

    Ok(documents)
}

pub(crate) fn resolve_manifest(
    client: &Client,
    default_namespace: &str,
    document: ManifestDocument,
) -> Result<ResolvedManifest, BlockError> {
    let (api_resource, scope) = discover_resource(client, &document.api_version, &document.kind)?;
    let namespace = match scope {
        Scope::Cluster => None,
        Scope::Namespaced => Some(
            document
                .namespace
                .clone()
                .unwrap_or_else(|| default_namespace.to_string()),
        ),
    };

    Ok(ResolvedManifest {
        document,
        api_resource,
        scope,
        namespace,
    })
}

pub(crate) fn discover_resource(
    client: &Client,
    api_version: &str,
    kind: &str,
) -> Result<(ApiResource, Scope), BlockError> {
    let gvk = group_version_kind(api_version, kind);
    let (api_resource, capabilities) = RUNTIME
        .block_on(discovery::pinned_kind(client, &gvk))
        .map_err(|error| BlockError::new("kubernetes", "discover resource", error))?;
    Ok((api_resource, capabilities.scope))
}

pub(crate) fn group_version_kind(api_version: &str, kind: &str) -> GroupVersionKind {
    if let Some((group, version)) = api_version.split_once('/') {
        GroupVersionKind::gvk(group, version, kind)
    } else {
        GroupVersionKind::gvk("", api_version, kind)
    }
}

pub(crate) fn json_value<T>(value: &T, operation: &str) -> Result<Value, BlockError>
where
    T: serde::Serialize,
{
    serde_json::to_value(value).map_err(|error| BlockError::new("kubernetes", operation, error))
}
