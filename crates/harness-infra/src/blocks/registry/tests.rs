use std::collections::BTreeSet;

use super::all_denied_binaries;

#[test]
fn denied_binaries_cover_managed_cluster_tools() {
    let expected: BTreeSet<String> = [
        "docker",
        "helm",
        "k3d",
        "kubectl",
        "kubectl-validate",
        "kumactl",
    ]
    .into_iter()
    .map(ToString::to_string)
    .collect();

    assert_eq!(
        all_denied_binaries(),
        expected,
        "managed cluster/mesh denied binaries changed"
    );
}
