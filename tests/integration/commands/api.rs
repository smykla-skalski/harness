// Integration tests for the `harness api` command.
// Tests error paths since happy path requires a real CP.

use harness::cli::Command;
use harness::commands::RunDirArgs;
use harness::commands::run::ApiMethod;

use super::super::helpers::*;

fn run_dir_args_missing() -> RunDirArgs {
    RunDirArgs {
        run_dir: Some("/nonexistent/run-dir".into()),
        run_id: None,
        run_root: None,
    }
}

#[test]
fn api_get_missing_run_dir() {
    let method = ApiMethod::Get {
        path: "/zones".to_string(),
        run_dir: run_dir_args_missing(),
    };
    let result = run_command(Command::Api(harness::commands::run::ApiArgs { method }));
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code(), "KSRCLI014");
}

#[test]
fn api_post_missing_run_dir() {
    let method = ApiMethod::Post {
        path: "/tokens/dataplane".to_string(),
        body: "{}".to_string(),
        run_dir: run_dir_args_missing(),
    };
    let result = run_command(Command::Api(harness::commands::run::ApiArgs { method }));
    assert!(result.is_err());
}

#[test]
fn api_delete_missing_run_dir() {
    let method = ApiMethod::Delete {
        path: "/meshes/default".to_string(),
        run_dir: run_dir_args_missing(),
    };
    let result = run_command(Command::Api(harness::commands::run::ApiArgs { method }));
    assert!(result.is_err());
}

#[test]
fn api_get_missing_cluster_spec() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "api-no-cluster", "single-zone");

    let method = ApiMethod::Get {
        path: "/zones".to_string(),
        run_dir: RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        },
    };
    let result = run_command(Command::Api(harness::commands::run::ApiArgs { method }));
    assert!(result.is_err());
    let err = result.unwrap_err();
    // Missing cluster spec means no CP address
    assert_eq!(err.code(), "KSRCLI009");
}

#[test]
fn api_post_missing_cluster_spec() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "api-post-no-cluster", "single-zone");

    let method = ApiMethod::Post {
        path: "/tokens/dataplane".to_string(),
        body: r#"{"name":"test"}"#.to_string(),
        run_dir: RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        },
    };
    let result = run_command(Command::Api(harness::commands::run::ApiArgs { method }));
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert_eq!(err.code(), "KSRCLI009");
}
