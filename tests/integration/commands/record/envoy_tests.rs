use std::fs;

use harness::run::{EnvoyArgs, EnvoyCommand, RunDirArgs};

use super::super::super::helpers::*;

#[test]
fn envoy_capture_records_admin_artifact() {
    let cmd = EnvoyCommand::Capture {
        phase: Some("verify".into()),
        label: "config-dump".into(),
        cluster: None,
        namespace: "default".into(),
        workload: "deploy/demo-client".into(),
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        type_contains: None,
        grep: None,
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = envoy_cmd(EnvoyArgs { cmd }).execute();
    assert!(result.is_ok(), "envoy capture should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);
}

#[test]
fn envoy_capture_can_filter_config_type() {
    let cmd = EnvoyCommand::Capture {
        phase: Some("verify".into()),
        label: "bootstrap-only".into(),
        cluster: None,
        namespace: "default".into(),
        workload: "deploy/demo-client".into(),
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        type_contains: Some("bootstrap".into()),
        grep: None,
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = envoy_cmd(EnvoyArgs { cmd }).execute();
    assert!(result.is_ok());
}

#[test]
fn envoy_route_body_can_capture_live_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let config_file = tmp.path().join("config_dump.json");

    let config = serde_json::json!({
        "configs": [{
            "dynamic_route_configs": [{
                "route_config": {
                    "virtual_hosts": [{
                        "name": "local",
                        "routes": [{
                            "match": { "prefix": "/stats" },
                            "route": { "cluster": "local" }
                        }]
                    }]
                }
            }]
        }]
    });
    fs::write(&config_file, serde_json::to_string_pretty(&config).unwrap()).unwrap();

    let cmd = EnvoyCommand::RouteBody {
        file: Some(config_file.to_string_lossy().to_string()),
        route_match: "/stats".into(),
        phase: None,
        label: None,
        cluster: None,
        namespace: None,
        workload: None,
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = envoy_cmd(EnvoyArgs { cmd }).execute();
    assert!(
        result.is_ok(),
        "route-body should find /stats route: {result:?}"
    );
}

#[test]
fn envoy_capture_rejects_without_tracked_cluster() {
    let cmd = EnvoyCommand::RouteBody {
        file: None,
        route_match: "/stats".into(),
        phase: None,
        label: None,
        cluster: None,
        namespace: None,
        workload: None,
        container: "kuma-sidecar".into(),
        admin_path: "/config_dump".into(),
        admin_host: "127.0.0.1".into(),
        admin_port: 9901,
        format: "auto".into(),
        run_dir: RunDirArgs {
            run_dir: None,
            run_id: None,
            run_root: None,
        },
    };
    let result = envoy_cmd(EnvoyArgs { cmd }).execute();
    assert!(result.is_err(), "should fail without --file");
}
