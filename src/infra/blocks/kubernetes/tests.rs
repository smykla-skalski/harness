use std::fs;
use std::path::Path;
use std::sync::Arc;

use temp_env::with_vars;

use super::fake::FakeKubernetesResponse;
use super::*;
use crate::infra::blocks::{FakeProcessExecutor, FakeProcessMethod, FakeResponse};
use crate::infra::exec::CommandResult;

fn success_result(args: &[&str], stdout: &str) -> CommandResult {
    CommandResult {
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
        returncode: 0,
        stdout: stdout.to_string(),
        stderr: String::new(),
    }
}

#[test]
fn kubectl_runtime_includes_kubeconfig() {
    let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "kubectl".to_string(),
        expected_args: Some(vec![
            "kubectl".into(),
            "--kubeconfig".into(),
            "/tmp/kubeconfig".into(),
            "get".into(),
            "pods".into(),
            "--all-namespaces".into(),
            "-o".into(),
            "json".into(),
        ]),
        expected_method: Some(FakeProcessMethod::Run),
        result: Ok(success_result(
            &[
                "kubectl",
                "--kubeconfig",
                "/tmp/kubeconfig",
                "get",
                "pods",
                "--all-namespaces",
                "-o",
                "json",
            ],
            r#"{"items":[]}"#,
        )),
    }]));
    let runtime = KubectlRuntime::new(fake);

    let pods = runtime
        .list_pods(Some(Path::new("/tmp/kubeconfig")))
        .expect("expected kubectl pod list to succeed");

    assert!(pods.is_empty());
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
fn kubectl_runtime_list_pods_parses_json() {
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
    let runtime = KubectlRuntime::new(fake);

    let pods = runtime.list_pods(None).expect("expected pod list");
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
fn fake_kubernetes_runtime_records_invocations() {
    let fake = FakeKubernetesRuntime::new(vec![FakeKubernetesResponse::Pods(Ok(vec![]))]);

    fake.list_pods(None).expect("expected success");

    let invocations = fake.invocations();
    assert_eq!(invocations.len(), 1);
    assert_eq!(invocations[0].operation, "list_pods");
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

    assert_send_sync::<KubectlRuntime>();
    assert_send_sync::<K3dClusterManager>();
    assert_send_sync::<PodSnapshot>();
}

#[test]
fn kube_runtime_dead_kubeconfig_returns_error_without_panicking() {
    let temp_dir = tempfile::tempdir().expect("expected temp dir");
    let kubeconfig = temp_dir.path().join("dead-kubeconfig.yaml");
    fs::write(
        &kubeconfig,
        r#"apiVersion: v1
kind: Config
clusters:
  - name: dead
    cluster:
      server: https://127.0.0.1:65535
      insecure-skip-tls-verify: true
contexts:
  - name: dead
    context:
      cluster: dead
      user: dead
current-context: dead
preferences: {}
users:
  - name: dead
    user:
      token: dead-token
"#,
    )
    .expect("expected kubeconfig write to succeed");

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        KubeRuntime::new().list_pods(Some(kubeconfig.as_path()))
    }));

    assert!(result.is_ok(), "native kube runtime should not panic");
    assert!(
        result.expect("catch_unwind should return result").is_err(),
        "dead kubeconfig should still return an error"
    );
}

#[test]
fn kubernetes_backend_defaults_to_kube() {
    with_vars([(KUBERNETES_RUNTIME_ENV, None::<&str>)], || {
        assert_eq!(
            kubernetes_backend_from_env().expect("expected default backend"),
            KubernetesRuntimeBackend::Kube
        );
    });
}

#[test]
fn kubernetes_backend_parses_kubectl_cli() {
    with_vars([(KUBERNETES_RUNTIME_ENV, Some("kubectl-cli"))], || {
        assert_eq!(
            kubernetes_backend_from_env().expect("expected kubectl-cli backend"),
            KubernetesRuntimeBackend::KubectlCli
        );
    });
}

#[test]
fn kubernetes_backend_rejects_invalid_value() {
    with_vars([(KUBERNETES_RUNTIME_ENV, Some("bad"))], || {
        let error = kubernetes_backend_from_env().expect_err("expected invalid selector");
        assert!(
            error
                .to_string()
                .contains("expected `kube` or `kubectl-cli`"),
            "unexpected error: {error}"
        );
    });
}

mod contracts {
    use super::*;

    fn contract_rollout_restart_empty_namespaces(
        runtime: &dyn KubernetesRuntime,
        kubeconfig: Option<&Path>,
    ) {
        runtime
            .rollout_restart(kubeconfig, &[])
            .expect("rollout_restart with empty namespaces should be a no-op");
    }

    fn contract_list_pods_returns_list(runtime: &dyn KubernetesRuntime, kubeconfig: Option<&Path>) {
        let pods = runtime
            .list_pods(kubeconfig)
            .expect("list_pods should succeed");
        let _ = pods.len();
    }

    #[test]
    fn fake_satisfies_rollout_restart_empty_namespaces() {
        let fake = FakeKubernetesRuntime::new(vec![]);
        contract_rollout_restart_empty_namespaces(&fake, None);
    }

    #[test]
    fn fake_satisfies_list_pods_returns_list() {
        let fake = FakeKubernetesRuntime::new(vec![FakeKubernetesResponse::Pods(Ok(vec![]))]);
        contract_list_pods_returns_list(&fake, None);
    }
}
