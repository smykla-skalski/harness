// Integration tests for the `harness api` command.
// Tests error paths since happy path requires a real CP.

use harness::run::RunDirArgs;
use harness::run::commands::{ApiArgs, ApiMethod};

use super::super::helpers::*;

fn run_dir_args_missing() -> RunDirArgs {
    RunDirArgs {
        run_dir: Some("/nonexistent/run-dir".into()),
        run_id: None,
        run_root: None,
    }
}

#[test]
fn api_missing_run_dir() {
    let make_methods: [fn() -> ApiMethod; 3] = [
        || ApiMethod::Get {
            path: "/zones".to_string(),
            run_dir: run_dir_args_missing(),
        },
        || ApiMethod::Post {
            path: "/tokens/dataplane".to_string(),
            body: "{}".to_string(),
            run_dir: run_dir_args_missing(),
        },
        || ApiMethod::Delete {
            path: "/meshes/default".to_string(),
            run_dir: run_dir_args_missing(),
        },
    ];
    for make in &make_methods {
        let result = run_command(api_cmd(ApiArgs { method: make() }));
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code(), "KSRCLI014");
    }
}

#[test]
fn api_missing_cluster_spec() {
    // Missing cluster spec means no CP address (KSRCLI009) for both Get and Post.
    for (name, is_post) in [("api-no-cluster", false), ("api-post-no-cluster", true)] {
        let tmp = tempfile::tempdir().unwrap();
        let run_dir = init_run(tmp.path(), name, "single-zone");
        let run_dir_args = RunDirArgs {
            run_dir: Some(run_dir),
            run_id: None,
            run_root: None,
        };
        let method = if is_post {
            ApiMethod::Post {
                path: "/tokens/dataplane".to_string(),
                body: r#"{"name":"test"}"#.to_string(),
                run_dir: run_dir_args,
            }
        } else {
            ApiMethod::Get {
                path: "/zones".to_string(),
                run_dir: run_dir_args,
            }
        };
        let result = run_command(api_cmd(ApiArgs { method }));
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code(), "KSRCLI009");
    }
}
