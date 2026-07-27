use std::collections::BTreeSet;

/// CLI names of the managed cluster and mesh tools a managed agent may not
/// create or invoke mid-session.
///
/// The suite workflow once declared these as preflight requirements, named
/// after the tools they gated (Docker, Kubernetes, Helm, Kuma, and so on).
/// That workflow is retired, and matching or parsing those requirement names
/// has no remaining reader. Only this union of binary names survives: the
/// ACP protocol reads it through `all_denied_binaries` below as the set an
/// agent may not create.
const DENIED_BINARIES: &[&str] = &[
    "docker",
    "helm",
    "k3d",
    "kubectl",
    "kubectl-validate",
    "kumactl",
];

/// The set of binaries a managed agent may not create or invoke mid-session.
///
/// This is the single source the ACP protocol reads to build
/// `HarnessAcpClient`, which enforces it on both the write surface
/// (`agents::policy::evaluate_write`) and terminal command creation
/// (`agents::acp::client::terminal::policy::denied_binary_name`).
#[must_use]
pub fn all_denied_binaries() -> BTreeSet<String> {
    DENIED_BINARIES.iter().copied().map(ToString::to_string).collect()
}

#[cfg(test)]
#[path = "registry/tests.rs"]
mod tests;
