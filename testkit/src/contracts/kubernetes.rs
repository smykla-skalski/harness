use harness::infra::blocks::KubernetesRuntime;

/// `list_pods` returns a (possibly empty) list without error.
///
/// # Panics
/// Panics if `list_pods` returns an error.
pub fn contract_list_pods_returns_list(
    operator: &dyn KubernetesRuntime,
    kubeconfig: Option<&std::path::Path>,
) {
    let pods = operator
        .list_pods(kubeconfig)
        .expect("list_pods should succeed");
    let _ = pods.len();
}

/// `rollout_restart` on an empty namespace list is a no-op.
///
/// # Panics
/// Panics if the no-op restart returns an error.
pub fn contract_rollout_restart_empty_namespaces(
    operator: &dyn KubernetesRuntime,
    kubeconfig: Option<&std::path::Path>,
) {
    operator
        .rollout_restart(kubeconfig, &[])
        .expect("rollout_restart with empty namespaces should be a no-op");
}

#[cfg(test)]
mod tests;
