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
#[path = "cleanup/tests.rs"]
mod tests;
