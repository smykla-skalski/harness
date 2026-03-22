use super::*;
use harness::infra::blocks::KubectlRuntime;

fn production_operator() -> KubectlRuntime {
    use harness::infra::blocks::StdProcessExecutor;
    use std::sync::Arc;
    KubectlRuntime::new(Arc::new(StdProcessExecutor))
}

#[test]
#[ignore] // needs kubectl + cluster
fn production_list_pods_returns_list() {
    contract_list_pods_returns_list(&production_operator(), None);
}

#[test]
#[ignore]
fn production_rollout_restart_empty_namespaces() {
    contract_rollout_restart_empty_namespaces(&production_operator(), None);
}
