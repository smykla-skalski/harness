use std::path::PathBuf;

use super::*;

#[test]
fn cluster_check_errors_on_nonexistent_run_dir() {
    let args = RunDirArgs {
        run_dir: Some(PathBuf::from("/tmp/harness-test-nonexistent-xyz")),
        run_id: None,
        run_root: None,
    };
    let error = cluster_check(&args).unwrap_err();
    assert!(
        error.code() == "KSRCLI014" || error.code() == "KSRCLI009",
        "unexpected error code: {}",
        error.code()
    );
}
