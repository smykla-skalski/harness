use std::collections::BTreeSet;
use std::fmt;
use std::str::FromStr;

use crate::infra::blocks::BlockRequirement;

#[must_use]
pub fn managed_cluster_binaries() -> BTreeSet<String> {
    BlockRequirement::ALL
        .iter()
        .flat_map(|requirement| requirement.denied_binaries().iter().copied())
        .map(ToString::to_string)
        .collect()
}

/// Hints that indicate direct Envoy admin access.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum AdminEndpointHint {
    LocalhostEnvoy,
    ConfigDump,
    Clusters,
    Listeners,
    Routes,
}

impl AdminEndpointHint {
    pub const ALL: &[Self] = &[
        Self::LocalhostEnvoy,
        Self::ConfigDump,
        Self::Clusters,
        Self::Listeners,
        Self::Routes,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::LocalhostEnvoy => "localhost:9901",
            Self::ConfigDump => "/config_dump",
            Self::Clusters => "/clusters",
            Self::Listeners => "/listeners",
            Self::Routes => "/routes",
        }
    }

    #[must_use]
    pub fn contains_hint(word: &str) -> bool {
        Self::ALL.iter().any(|hint| word.contains(hint.as_str()))
    }
}

impl fmt::Display for AdminEndpointHint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for AdminEndpointHint {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .iter()
            .find(|hint| hint.as_str() == s)
            .copied()
            .ok_or(())
    }
}
