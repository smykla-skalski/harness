use std::path::Path;
use std::sync::Arc;

use super::*;
use crate::infra::blocks::{FakeProcessExecutor, FakeProcessMethod, FakeResponse};

fn success_result(args: &[&str], stdout: &str) -> CommandResult {
    CommandResult {
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        returncode: 0,
        stdout: stdout.to_string(),
        stderr: String::new(),
    }
}

#[test]
fn kubectl_operator_includes_kubeconfig() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "kubectl".to_string(),
        expected_args: Some(vec![
            "kubectl".into(),
            "--kubeconfig".into(),
            "/tmp/kubeconfig".into(),
            "get".into(),
            "pods".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &["kubectl", "--kubeconfig", "/tmp/kubeconfig", "get", "pods"],
            "",
        )),
    }]));
    let operator = KubectlOperator::new(fake);

    let result = operator
        .run(Some(Path::new("/tmp/kubeconfig")), &["get", "pods"], &[0])
        .expect("expected kubectl run to succeed");

    assert_eq!(result.returncode, 0);
}

fn assert_demo_pod(pod: &PodSnapshot) {
    assert_eq!(pod.namespace.as_deref(), Some("default"));
    assert_eq!(pod.name.as_deref(), Some("demo-123"));
    assert_eq!(pod.ready.as_deref(), Some("1/2"));
    assert_eq!(pod.status.as_deref(), Some("Running"));
    assert_eq!(pod.restarts, Some(3));
    assert_eq!(pod.node.as_deref(), Some("node-a"));
}

#[test]
fn kubectl_operator_list_pods_parses_json() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "kubectl".to_string(),
        expected_args: None,
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &["kubectl", "get", "pods", "--all-namespaces", "-o", "json"],
            r#"{
              "items": [
                {
                  "metadata": { "namespace": "default", "name": "demo-123" },
                  "spec": { "nodeName": "node-a" },
                  "status": {
                    "phase": "Running",
                    "containerStatuses": [
                      { "ready": true, "restartCount": 1 },
                      { "ready": false, "restartCount": 2 }
                    ]
                  }
                }
              ]
            }"#,
        )),
    }]));
    let operator = KubectlOperator::new(fake);

    let pods = operator.list_pods(None).expect("expected pod list");
    assert_eq!(pods.len(), 1);
    assert_demo_pod(&pods[0]);
}

#[test]
fn pod_snapshots_from_json_keeps_container_counts() {
    let pods = super::pods::pod_snapshots_from_json(
        r#"{
          "items": [
            {
              "metadata": { "namespace": "ns", "name": "demo" },
              "spec": { "nodeName": "node-x" },
              "status": {
                "phase": "Running",
                "containerStatuses": [
                  { "ready": true, "restartCount": 2 },
                  { "ready": false, "restartCount": 3 }
                ]
              }
            }
          ]
        }"#,
    )
    .expect("expected typed pod parser to succeed");

    assert_eq!(pods.len(), 1);
    assert_eq!(pods[0].ready.as_deref(), Some("1/2"));
    assert_eq!(pods[0].restarts, Some(5));
    assert_eq!(pods[0].node.as_deref(), Some("node-x"));
}

#[test]
fn k3d_cluster_manager_detects_existing_cluster() {
    let fake_process = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "k3d".to_string(),
        expected_args: Some(vec![
            "k3d".into(),
            "cluster".into(),
            "list".into(),
            "--no-headers".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &["k3d", "cluster", "list", "--no-headers"],
            "demo 1/1 0/0\n",
        )),
    }]));
    let manager = K3dClusterManager::new(fake_process);

    let exists = manager
        .cluster_exists("demo")
        .expect("expected cluster_exists to succeed");

    assert!(exists);
}

#[test]
fn fake_kubernetes_operator_records_invocations() {
    let fake =
        FakeKubernetesOperator::new(vec![Ok(success_result(&["kubectl", "get", "pods"], ""))]);

    fake.run(None, &["get", "pods"], &[0])
        .expect("expected success");

    let invocations = fake.invocations();
    assert_eq!(invocations.len(), 1);
    assert_eq!(invocations[0].args, vec!["get", "pods"]);
}

#[test]
fn fake_local_cluster_manager_records_invocations() {
    let fake = FakeLocalClusterManager::new(vec![Ok(success_result(
        &["k3d", "cluster", "stop", "demo"],
        "",
    ))]);

    fake.stop_cluster("demo").expect("expected success");

    let invocations = fake.invocations();
    assert_eq!(invocations.len(), 1);
    assert_eq!(invocations[0].args, vec!["cluster", "stop", "demo"]);
}

#[test]
fn kubernetes_block_types_are_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}

    assert_send_sync::<KubectlOperator>();
    assert_send_sync::<K3dClusterManager>();
    assert_send_sync::<PodSnapshot>();
}

mod contracts {
    use super::*;

    fn contract_rollout_restart_empty_namespaces(
        operator: &dyn KubernetesOperator,
        kubeconfig: Option<&Path>,
    ) {
        operator
            .rollout_restart(kubeconfig, &[])
            .expect("rollout_restart with empty namespaces should be a no-op");
    }

    fn contract_list_pods_returns_list(
        operator: &dyn KubernetesOperator,
        kubeconfig: Option<&Path>,
    ) {
        let pods = operator
            .list_pods(kubeconfig)
            .expect("list_pods should succeed");
        let _ = pods.len();
    }

    #[test]
    fn fake_satisfies_rollout_restart_empty_namespaces() {
        let fake = FakeKubernetesOperator::new(vec![]);
        contract_rollout_restart_empty_namespaces(&fake, None);
    }

    #[test]
    fn fake_satisfies_list_pods_returns_list() {
        let fake = FakeKubernetesOperator::new(vec![Ok(success_result(
            &["kubectl", "get", "pods", "--all-namespaces", "-o", "json"],
            r#"{"items":[]}"#,
        ))]);
        contract_list_pods_returns_list(&fake, None);
    }
}
