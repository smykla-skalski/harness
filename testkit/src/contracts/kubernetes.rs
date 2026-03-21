use harness::infra::blocks::KubernetesOperator;

/// `run` with a simple kubectl subcommand returns a result.
///
/// # Panics
/// Panics if the kubectl command fails.
pub fn contract_run_returns_result(
    operator: &dyn KubernetesOperator,
    kubeconfig: Option<&std::path::Path>,
) {
    let result = operator
        .run(kubeconfig, &["version", "--client", "-o", "json"], &[0])
        .expect("kubectl version --client should succeed");
    assert_eq!(result.returncode, 0);
    assert!(
        !result.stdout.is_empty(),
        "kubectl version output should not be empty"
    );
}

/// `list_pods` returns a (possibly empty) list without error.
///
/// # Panics
/// Panics if `list_pods` returns an error.
pub fn contract_list_pods_returns_list(
    operator: &dyn KubernetesOperator,
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
    operator: &dyn KubernetesOperator,
    kubeconfig: Option<&std::path::Path>,
) {
    operator
        .rollout_restart(kubeconfig, &[])
        .expect("rollout_restart with empty namespaces should be a no-op");
}

#[cfg(test)]
mod tests;
