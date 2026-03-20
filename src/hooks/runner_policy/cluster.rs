use std::collections::BTreeSet;
use std::fmt;
use std::str::FromStr;

use crate::infra::blocks::BlockRequirement;
use crate::kernel::gate::Gate;

pub const PREFLIGHT_REPLY_HEAD: &str = "suite:run/preflight:";

pub const MANIFEST_FIX_GATE: Gate = Gate {
    question: "suite:run/manifest-fix: how should this failure be handled?",
    options: &[
        "Fix for this run only",
        "Fix in suite and this run",
        "Skip this step",
        "Stop run",
    ],
};

#[must_use]
pub fn managed_cluster_binaries() -> BTreeSet<String> {
    BlockRequirement::ALL
        .iter()
        .flat_map(|requirement| requirement.denied_binaries().iter().copied())
        .map(ToString::to_string)
        .collect()
}

/// Preflight reply status.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum PreflightReply {
    Pass,
    Fail,
}

impl fmt::Display for PreflightReply {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Pass => "pass",
            Self::Fail => "fail",
        })
    }
}

impl FromStr for PreflightReply {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "pass" => Ok(Self::Pass),
            "fail" => Ok(Self::Fail),
            _ => Err(()),
        }
    }
}

/// Legacy Python scripts that are no longer allowed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum LegacyScript {
    ApplyTrackedManifest,
    CaptureState,
    ClusterLifecycle,
    InstallGatewayApiCrds,
    Preflight,
    RecordCommand,
    ValidateManifest,
}

impl LegacyScript {
    #[must_use]
    pub fn is_denied(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for LegacyScript {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ApplyTrackedManifest => "apply_tracked_manifest.py",
            Self::CaptureState => "capture_state.py",
            Self::ClusterLifecycle => "cluster_lifecycle.py",
            Self::InstallGatewayApiCrds => "install_gateway_api_crds.py",
            Self::Preflight => "preflight.py",
            Self::RecordCommand => "record_command.py",
            Self::ValidateManifest => "validate_manifest.py",
        })
    }
}

impl FromStr for LegacyScript {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "apply_tracked_manifest.py" => Ok(Self::ApplyTrackedManifest),
            "capture_state.py" => Ok(Self::CaptureState),
            "cluster_lifecycle.py" => Ok(Self::ClusterLifecycle),
            "install_gateway_api_crds.py" => Ok(Self::InstallGatewayApiCrds),
            "preflight.py" => Ok(Self::Preflight),
            "record_command.py" => Ok(Self::RecordCommand),
            "validate_manifest.py" => Ok(Self::ValidateManifest),
            _ => Err(()),
        }
    }
}

/// Binaries the runner must not invoke directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum RunnerBinary {
    Gh,
}

impl RunnerBinary {
    #[must_use]
    pub fn is_denied(name: &str) -> bool {
        Self::from_str(name).is_ok()
    }
}

impl fmt::Display for RunnerBinary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Gh => "gh",
        })
    }
}

impl FromStr for RunnerBinary {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "gh" => Ok(Self::Gh),
            _ => Err(()),
        }
    }
}

/// Make target prefixes that imply cluster provisioning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum MakeTargetPrefix {
    K3d,
    Kind,
}

impl MakeTargetPrefix {
    pub const ALL: &[Self] = &[Self::K3d, Self::Kind];

    #[must_use]
    pub fn is_denied_target(target: &str) -> bool {
        Self::ALL.iter().any(|prefix| {
            let raw = match prefix {
                Self::K3d => "k3d/",
                Self::Kind => "kind/",
            };
            target.starts_with(raw)
        })
    }
}

impl fmt::Display for MakeTargetPrefix {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::K3d => "k3d/",
            Self::Kind => "kind/",
        })
    }
}

impl FromStr for MakeTargetPrefix {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "k3d/" => Ok(Self::K3d),
            "kind/" => Ok(Self::Kind),
            _ => Err(()),
        }
    }
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
