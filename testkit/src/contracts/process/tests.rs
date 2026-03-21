use super::*;
use harness::infra::blocks::StdProcessExecutor;

#[test]
#[ignore] // needs real system binaries
fn production_run_returns_output() {
    contract_run_returns_output(&StdProcessExecutor);
}

#[test]
#[ignore]
fn production_run_rejects_bad_exit_code() {
    contract_run_rejects_bad_exit_code(&StdProcessExecutor);
}

#[test]
#[ignore]
fn production_run_accepts_listed_exit_code() {
    contract_run_accepts_listed_exit_code(&StdProcessExecutor);
}

#[test]
#[ignore]
fn production_run_streaming_returns_output() {
    contract_run_streaming_returns_output(&StdProcessExecutor);
}

#[test]
#[ignore]
fn production_run_inherited_returns_exit_code() {
    contract_run_inherited_returns_exit_code(&StdProcessExecutor);
}
