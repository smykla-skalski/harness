use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Captured Kubernetes pod summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KubernetesPodSnapshot {
    pub namespace: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    #[serde(default)]
    pub ready: bool,
}

/// Captured Kubernetes cluster state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KubernetesCaptureSnapshot {
    #[serde(default)]
    pub pods: Vec<KubernetesPodSnapshot>,
}

/// Captured Docker container summary for universal runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DockerContainerSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub networks: Option<String>,
}

/// Captured universal dataplane summary.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UniversalDataplaneSnapshot {
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mesh: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

/// Typed wrapper for universal dataplane query results.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UniversalDataplaneCollection {
    #[serde(default)]
    pub items: Vec<UniversalDataplaneSnapshot>,
    #[serde(default, flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

impl UniversalDataplaneCollection {
    #[must_use]
    pub fn from_api_value(value: serde_json::Value) -> Self {
        let serde_json::Value::Object(mut object) = value else {
            return Self::default();
        };
        let items = object
            .remove("items")
            .and_then(|value| match value {
                serde_json::Value::Array(items) => Some(
                    items
                        .into_iter()
                        .map(UniversalDataplaneSnapshot::from_api_value)
                        .collect(),
                ),
                _ => None,
            })
            .unwrap_or_default();
        Self {
            items,
            extra: object.into_iter().collect(),
        }
    }
}

impl UniversalDataplaneSnapshot {
    #[must_use]
    pub fn from_api_value(value: serde_json::Value) -> Self {
        let serde_json::Value::Object(mut object) = value else {
            return Self::default();
        };
        let name = take_string(&mut object, "name")
            .or_else(|| nested_string(&object, &["meta", "name"]))
            .or_else(|| nested_string(&object, &["dataplane", "name"]))
            .unwrap_or_default();
        let mesh = take_string(&mut object, "mesh")
            .or_else(|| nested_string(&object, &["meta", "mesh"]))
            .or_else(|| nested_string(&object, &["dataplane", "mesh"]));
        let address = nested_string(&object, &["networking", "address"])
            .or_else(|| nested_string(&object, &["dataplane", "networking", "address"]));
        Self {
            name,
            mesh,
            address,
            extra: object.into_iter().collect(),
        }
    }
}

/// Captured universal cluster state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UniversalCaptureSnapshot {
    #[serde(default)]
    pub containers: Vec<DockerContainerSnapshot>,
    #[serde(default)]
    pub dataplanes: UniversalDataplaneCollection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dataplanes_error: Option<String>,
}

/// Typed wrapper for run state captures.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "platform", rename_all = "snake_case")]
pub enum StateCaptureSnapshot {
    Kubernetes(KubernetesCaptureSnapshot),
    Universal(UniversalCaptureSnapshot),
}

fn take_string(
    object: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
) -> Option<String> {
    object
        .remove(key)
        .and_then(|value| value.as_str().map(str::to_string))
}

fn nested_string(
    object: &serde_json::Map<String, serde_json::Value>,
    path: &[&str],
) -> Option<String> {
    let mut value = object.get(path.first().copied()?)?;
    for segment in &path[1..] {
        value = value.get(*segment)?;
    }
    value.as_str().map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dataplane_collection_extracts_known_fields() {
        let value = serde_json::json!({
            "total": 1,
            "items": [
                {
                    "name": "dp-1",
                    "mesh": "default",
                    "networking": {
                        "address": "192.0.2.10"
                    },
                    "healthy": true
                }
            ]
        });

        let collection = UniversalDataplaneCollection::from_api_value(value);

        assert_eq!(collection.items.len(), 1);
        assert_eq!(collection.items[0].name, "dp-1");
        assert_eq!(collection.items[0].mesh.as_deref(), Some("default"));
        assert_eq!(collection.items[0].address.as_deref(), Some("192.0.2.10"));
        assert_eq!(
            collection.items[0].extra.get("healthy"),
            Some(&serde_json::Value::Bool(true))
        );
        assert_eq!(
            collection.extra.get("total"),
            Some(&serde_json::Value::from(1))
        );
    }

    #[test]
    fn dataplane_snapshot_reads_nested_meta_fields() {
        let value = serde_json::json!({
            "meta": {
                "name": "dp-2",
                "mesh": "demo"
            },
            "dataplane": {
                "networking": {
                    "address": "198.51.100.8"
                }
            }
        });

        let snapshot = UniversalDataplaneSnapshot::from_api_value(value);

        assert_eq!(snapshot.name, "dp-2");
        assert_eq!(snapshot.mesh.as_deref(), Some("demo"));
        assert_eq!(snapshot.address.as_deref(), Some("198.51.100.8"));
    }
}
