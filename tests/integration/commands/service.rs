// Integration tests for the `harness service` command.
// Tests error paths for missing args and missing cluster spec.

use harness::run::RunDirArgs;
use harness::run::commands::ServiceArgs;

use super::super::helpers::*;

fn service_args(action: &str, name: Option<&str>, run_dir: RunDirArgs) -> ServiceArgs {
    ServiceArgs {
        action: action.to_string(),
        name: name.map(String::from),
        image: None,
        port: None,
        mesh: "default".to_string(),
        transparent_proxy: false,
        timeout: 60,
        dataplane_template: None,
        run_dir,
    }
}

#[test]
fn service_up_missing_name() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "svc-no-name", "single-zone");
    let args = service_args(
        "up",
        None,
        RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        },
    );
    let result = run_command(service_cmd(args));
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.message().contains("service name is required"));
}

#[test]
fn service_up_missing_port() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "svc-no-port", "single-zone");
    let args = service_args(
        "up",
        Some("demo"),
        RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        },
    );
    let result = run_command(service_cmd(args));
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.message().contains("service port is required"));
}

#[test]
fn service_unknown_action() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "svc-bad-action", "single-zone");
    let args = service_args(
        "restart",
        Some("demo"),
        RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        },
    );
    let result = run_command(service_cmd(args));
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.message().contains("unknown service action"));
}

#[test]
fn service_up_missing_cluster_spec() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "svc-no-cluster", "single-zone");
    let mut args = service_args(
        "up",
        Some("demo"),
        RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        },
    );
    args.port = Some(8080);
    args.image = Some("kuma-universal:latest".into());
    let result = run_command(service_cmd(args));
    assert!(result.is_err());
    let err = result.unwrap_err();
    // Missing cluster spec means no CP address
    assert_eq!(err.code(), "KSRCLI009");
}
