use super::*;
use crate::kernel::topology::{ClusterProvider, Platform};
use crate::setup::cluster::{ClusterArgs, RemoteClusterTarget};
use fs_err as fs;

fn remote_cluster_args(kubeconfig: &Path) -> ClusterArgs {
    ClusterArgs {
        mode: "single-up".into(),
        cluster_name: "kuma-1".into(),
        extra_cluster_names: vec![],
        platform: "kubernetes".into(),
        provider: Some("remote".into()),
        repo_root: None,
        run_dir: None,
        helm_setting: vec![],
        remote: vec![RemoteClusterTarget {
            name: "kuma-1".into(),
            kubeconfig: kubeconfig.display().to_string(),
            context: None,
        }],
        push_prefix: Some("registry.example.test/kuma".into()),
        push_tag: Some("latest".into()),
        namespace: "kuma-system".into(),
        release_name: "kuma".into(),
        restart_namespace: vec![],
        store: "memory".into(),
        image: None,
        no_build: false,
        no_load: false,
    }
}

#[test]
fn cluster_remote_k8s_rejects_no_load() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let kubeconfig = tmp.path().join("source-kubeconfig.yaml");
    fs::write(&kubeconfig, "apiVersion: v1\nkind: Config\n").unwrap();
    let mut args = remote_cluster_args(&kubeconfig);
    args.no_load = true;

    let spec = ClusterSpec::from_mode_with_platform_and_provider(
        "single-up",
        &[String::from("kuma-1")],
        &repo_root.to_string_lossy(),
        vec![],
        vec![],
        Platform::Kubernetes,
        ClusterProvider::Remote,
    )
    .unwrap();

    let error = cluster_remote_k8s(&args, &repo_root, &HashMap::new(), spec, &[]).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("--no-load is not valid with --provider remote")
    );
}

#[test]
fn remote_install_state_path_is_stable_across_sessions() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg_data = tmp.path().join("xdg-data");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let path_a = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_data.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-a")),
        ],
        || {
            let spec = ClusterSpec::from_mode_with_platform_and_provider(
                "single-up",
                &[String::from("kuma-1")],
                &repo_root.to_string_lossy(),
                vec![],
                vec![],
                Platform::Kubernetes,
                ClusterProvider::Remote,
            )
            .unwrap();
            remote_install_state_path_for_spec(&spec)
        },
    );

    let path_b = temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_data.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-b")),
        ],
        || {
            let spec = ClusterSpec::from_mode_with_platform_and_provider(
                "single-up",
                &[String::from("kuma-1")],
                &repo_root.to_string_lossy(),
                vec![],
                vec![],
                Platform::Kubernetes,
                ClusterProvider::Remote,
            )
            .unwrap();
            remote_install_state_path_for_spec(&spec)
        },
    );

    assert_eq!(path_a, path_b);
    assert!(path_a.to_string_lossy().contains("/projects/project-"));
    assert!(path_a.to_string_lossy().contains("/remote-kubernetes/"));
    assert!(!path_a.to_string_lossy().contains("contexts/session-"));
}
