use std::fmt;

use serde::{Deserialize, Serialize};

use super::error::BlockError;

/// Named block requirements declared by suites and validated at preflight time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum BlockRequirement {
    Docker,
    Compose,
    Kubernetes,
    K3d,
    Helm,
    Envoy,
    Kuma,
    Build,
}

impl BlockRequirement {
    pub const ALL: &[Self] = &[
        Self::Docker,
        Self::Compose,
        Self::Kubernetes,
        Self::K3d,
        Self::Helm,
        Self::Envoy,
        Self::Kuma,
        Self::Build,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Docker => "docker",
            Self::Compose => "compose",
            Self::Kubernetes => "kubernetes",
            Self::K3d => "k3d",
            Self::Helm => "helm",
            Self::Envoy => "envoy",
            Self::Kuma => "kuma",
            Self::Build => "build",
        }
    }

    #[must_use]
    pub fn denied_binaries(self) -> &'static [&'static str] {
        match self {
            Self::Docker | Self::Compose => &["docker"],
            Self::Kubernetes => &["kubectl", "kubectl-validate"],
            Self::K3d => &["k3d"],
            Self::Helm => &["helm"],
            Self::Kuma => &["kumactl"],
            Self::Envoy | Self::Build => &[],
        }
    }

    /// Parse a user- or suite-supplied requirement name.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` for unknown requirement names.
    pub fn parse(raw: &str) -> Result<Self, BlockError> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "docker" => Ok(Self::Docker),
            "compose" => Ok(Self::Compose),
            "kubernetes" => Ok(Self::Kubernetes),
            "k3d" => Ok(Self::K3d),
            "helm" => Ok(Self::Helm),
            "envoy" => Ok(Self::Envoy),
            "kuma" => Ok(Self::Kuma),
            "build" => Ok(Self::Build),
            other => Err(BlockError::message(
                "registry",
                "parse requirement",
                format!("unknown block requirement: {other}"),
            )),
        }
    }
}

impl fmt::Display for BlockRequirement {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
#[path = "registry/tests.rs"]
mod tests;
