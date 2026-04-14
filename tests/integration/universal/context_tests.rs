use super::*;

#[test]
fn run_context_loads_universal_cluster_from_state() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-uni-ctx", "single-zone");

    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("ctx-token-456".into());
    spec.docker_network = Some("harness-cp".into());
    spec.store_type = Some("memory".into());
    spec.members[0].container_ip = Some("172.57.0.5".into());

    let state_dir = run_dir.join("state");
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = context.cluster.unwrap();
    assert_eq!(cluster.platform, Platform::Universal);
    assert_eq!(cluster.admin_token.as_deref(), Some("ctx-token-456"));
    assert_eq!(cluster.docker_network.as_deref(), Some("harness-cp"));
    assert_eq!(cluster.store_type.as_deref(), Some("memory"));
    assert_eq!(
        cluster.members[0].container_ip.as_deref(),
        Some("172.57.0.5")
    );
}

#[test]
fn run_context_loads_kubernetes_cluster_from_state() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-k8s-ctx", "single-zone");

    let spec = ClusterSpec::from_mode(
        "single-up",
        &["kuma-test".into()],
        "/repo",
        vec![HelmSetting {
            key: "cp.mode".into(),
            value: "standalone".into(),
        }],
        vec![],
    )
    .unwrap();

    let state_dir = run_dir.join("state");
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = context.cluster.unwrap();
    assert_eq!(cluster.platform, Platform::Kubernetes);
    assert!(cluster.admin_token.is_none());
    assert!(cluster.docker_network.is_none());
}

#[test]
fn run_context_no_cluster_when_state_file_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-no-cluster", "single-zone");

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    assert!(context.cluster.is_none());
}

#[test]
fn command_env_universal_fields_in_dict() {
    let env = CommandEnv {
        profile: "single-zone-universal".into(),
        repo_root: "/repo".into(),
        run_dir: "/runs/r1".into(),
        run_id: "r1".into(),
        run_root: "/runs".into(),
        suite_dir: "/suites/s".into(),
        suite_id: "s".into(),
        suite_path: "/suites/s/suite.md".into(),
        kubeconfig: None,
        platform: Some("universal".into()),
        cp_api_url: Some("http://172.57.0.2:5681".into()),
        docker_network: Some("harness-net".into()),
    };
    let dict = env.to_env_dict();

    assert_eq!(dict.get("PLATFORM").unwrap(), "universal");
    assert_eq!(dict.get("CP_API_URL").unwrap(), "http://172.57.0.2:5681");
    assert_eq!(dict.get("DOCKER_NETWORK").unwrap(), "harness-net");
    assert!(!dict.contains_key("KUBECONFIG"));
    assert_eq!(dict.len(), 11);
}

#[test]
fn command_env_kubernetes_omits_universal_fields() {
    let env = CommandEnv {
        profile: "single-zone".into(),
        repo_root: "/repo".into(),
        run_dir: "/runs/r1".into(),
        run_id: "r1".into(),
        run_root: "/runs".into(),
        suite_dir: "/suites/s".into(),
        suite_id: "s".into(),
        suite_path: "/suites/s/suite.md".into(),
        kubeconfig: Some("/kube/config".into()),
        platform: None,
        cp_api_url: None,
        docker_network: None,
    };
    let dict = env.to_env_dict();

    assert!(!dict.contains_key("PLATFORM"));
    assert!(!dict.contains_key("CP_API_URL"));
    assert!(!dict.contains_key("DOCKER_NETWORK"));
    assert_eq!(dict.get("KUBECONFIG").unwrap(), "/kube/config");
    assert_eq!(dict.len(), 9);
}

#[test]
fn command_env_serialization_roundtrip_universal() {
    let env = CommandEnv {
        profile: "p".into(),
        repo_root: "/r".into(),
        run_dir: "/d".into(),
        run_id: "i".into(),
        run_root: "/rr".into(),
        suite_dir: "/sd".into(),
        suite_id: "si".into(),
        suite_path: "/sp".into(),
        kubeconfig: None,
        platform: Some("universal".into()),
        cp_api_url: Some("http://10.0.0.1:5681".into()),
        docker_network: Some("harness-cp".into()),
    };
    let json = serde_json::to_string(&env).unwrap();
    let back: CommandEnv = serde_json::from_str(&json).unwrap();
    assert_eq!(back.platform.as_deref(), Some("universal"));
    assert_eq!(back.cp_api_url.as_deref(), Some("http://10.0.0.1:5681"));
    assert_eq!(back.docker_network.as_deref(), Some("harness-cp"));
}

#[test]
fn run_layout_from_run_dir_universal_run() {
    let layout = RunLayout::from_run_dir(Path::new("/runs/universal-run-1"));
    assert_eq!(layout.run_id, "universal-run-1");
    assert_eq!(layout.run_root, "/runs");
    assert_eq!(
        layout.state_dir().to_string_lossy(),
        "/runs/universal-run-1/state"
    );
}

#[test]
fn capture_universal_resolves_context() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "cap-uni", "single-zone");

    let mut spec = ClusterSpec::from_mode_with_platform(
        "single-up",
        &["cp".into()],
        "/repo",
        vec![],
        vec![],
        Platform::Universal,
    )
    .unwrap();
    spec.admin_token = Some("tok-capture".into());
    spec.docker_network = Some("harness-cp".into());
    spec.members[0].container_ip = Some("172.57.0.2".into());

    let state_dir = run_dir.join("state");
    fs::write(
        state_dir.join("cluster.json"),
        serde_json::to_string_pretty(&spec).unwrap(),
    )
    .unwrap();

    let context = RunContext::from_run_dir(&run_dir).unwrap();
    let cluster = context.cluster.as_ref().unwrap();
    assert_eq!(cluster.platform, Platform::Universal);
    assert_eq!(cluster.docker_network.as_deref(), Some("harness-cp"));
}
