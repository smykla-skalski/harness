use serde::{Deserialize, Serialize};

/// A resource that needs to be cleaned up when a run completes or is torn down.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "name")]
pub enum CleanupResource {
    /// A Docker container to stop and remove.
    Container(String),
    /// A Docker network to remove.
    Network(String),
    /// A Docker volume to remove.
    Volume(String),
    /// A k3d or kind cluster to delete.
    Cluster(String),
}

impl CleanupResource {
    #[must_use]
    pub fn kind_label(&self) -> &'static str {
        match self {
            Self::Container(_) => "container",
            Self::Network(_) => "network",
            Self::Volume(_) => "volume",
            Self::Cluster(_) => "cluster",
        }
    }

    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::Container(name)
            | Self::Network(name)
            | Self::Volume(name)
            | Self::Cluster(name) => name,
        }
    }
}

/// Tracks resources created during a run so they can be cleaned up on
/// teardown. Serialized as JSON to the run directory.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CleanupManifest {
    pub resources: Vec<CleanupResource>,
}

impl CleanupManifest {
    #[must_use]
    pub fn new() -> Self {
        Self {
            resources: Vec::new(),
        }
    }

    /// Add a resource to the manifest if it is not already present.
    pub fn add(&mut self, resource: CleanupResource) {
        if !self.contains(&resource) {
            self.resources.push(resource);
        }
    }

    /// Returns `true` when the manifest already tracks this resource.
    #[must_use]
    pub fn contains(&self, resource: &CleanupResource) -> bool {
        self.resources.contains(resource)
    }

    /// Returns `true` when no resources are tracked.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.resources.is_empty()
    }

    /// Number of tracked resources.
    #[must_use]
    pub fn len(&self) -> usize {
        self.resources.len()
    }

    /// Iterator over resources of a specific kind.
    pub fn by_kind(&self, kind: &str) -> impl Iterator<Item = &CleanupResource> {
        self.resources
            .iter()
            .filter(move |resource| resource.kind_label() == kind)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_manifest_is_empty() {
        let manifest = CleanupManifest::new();
        assert!(manifest.is_empty());
        assert_eq!(manifest.len(), 0);
    }

    #[test]
    fn add_container() {
        let mut manifest = CleanupManifest::new();
        manifest.add(CleanupResource::Container("kuma-cp".to_string()));
        assert_eq!(manifest.len(), 1);
        assert!(!manifest.is_empty());
    }

    #[test]
    fn add_deduplicates() {
        let mut manifest = CleanupManifest::new();
        manifest.add(CleanupResource::Container("kuma-cp".to_string()));
        manifest.add(CleanupResource::Container("kuma-cp".to_string()));
        assert_eq!(manifest.len(), 1);
    }

    #[test]
    fn different_kinds_same_name_both_tracked() {
        let mut manifest = CleanupManifest::new();
        manifest.add(CleanupResource::Container("demo".to_string()));
        manifest.add(CleanupResource::Network("demo".to_string()));
        assert_eq!(manifest.len(), 2);
    }

    #[test]
    fn contains_check() {
        let mut manifest = CleanupManifest::new();
        let resource = CleanupResource::Volume("pgdata".to_string());
        assert!(!manifest.contains(&resource));
        manifest.add(resource.clone());
        assert!(manifest.contains(&resource));
    }

    #[test]
    fn by_kind_filters() {
        let mut manifest = CleanupManifest::new();
        manifest.add(CleanupResource::Container("cp".to_string()));
        manifest.add(CleanupResource::Network("harness-net".to_string()));
        manifest.add(CleanupResource::Container("dp".to_string()));
        manifest.add(CleanupResource::Cluster("test-cluster".to_string()));

        let containers: Vec<_> = manifest.by_kind("container").collect();
        assert_eq!(containers.len(), 2);

        let networks: Vec<_> = manifest.by_kind("network").collect();
        assert_eq!(networks.len(), 1);

        let clusters: Vec<_> = manifest.by_kind("cluster").collect();
        assert_eq!(clusters.len(), 1);

        let volumes: Vec<_> = manifest.by_kind("volume").collect();
        assert_eq!(volumes.len(), 0);
    }

    #[test]
    fn kind_label_values() {
        assert_eq!(
            CleanupResource::Container("x".to_string()).kind_label(),
            "container"
        );
        assert_eq!(
            CleanupResource::Network("x".to_string()).kind_label(),
            "network"
        );
        assert_eq!(
            CleanupResource::Volume("x".to_string()).kind_label(),
            "volume"
        );
        assert_eq!(
            CleanupResource::Cluster("x".to_string()).kind_label(),
            "cluster"
        );
    }

    #[test]
    fn name_accessor() {
        assert_eq!(
            CleanupResource::Container("kuma-cp".to_string()).name(),
            "kuma-cp"
        );
        assert_eq!(
            CleanupResource::Cluster("k3d-test".to_string()).name(),
            "k3d-test"
        );
    }

    #[test]
    fn serialization_roundtrip() {
        let mut manifest = CleanupManifest::new();
        manifest.add(CleanupResource::Container("cp".to_string()));
        manifest.add(CleanupResource::Network("harness-net".to_string()));
        manifest.add(CleanupResource::Volume("pgdata".to_string()));
        manifest.add(CleanupResource::Cluster("k3d-test".to_string()));

        let json = serde_json::to_string_pretty(&manifest).unwrap();
        let back: CleanupManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(manifest, back);
    }

    #[test]
    fn deserialization_from_json() {
        let json = r#"{
            "resources": [
                {"kind": "Container", "name": "kuma-cp"},
                {"kind": "Network", "name": "harness-net"}
            ]
        }"#;
        let manifest: CleanupManifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.len(), 2);
        assert_eq!(manifest.resources[0].kind_label(), "container");
        assert_eq!(manifest.resources[0].name(), "kuma-cp");
        assert_eq!(manifest.resources[1].kind_label(), "network");
        assert_eq!(manifest.resources[1].name(), "harness-net");
    }

    #[test]
    fn default_is_empty() {
        let manifest = CleanupManifest::default();
        assert!(manifest.is_empty());
    }
}
