use std::env;
use std::process::{Command, Output};
use std::thread;

use regex::Regex;
use tokio::runtime::Builder as RuntimeBuilder;

use super::provider_sync_execution::run_provider_sync_task;

const PROVIDER_STACK_CHILD_ENV: &str = "HARNESS_TEST_PROVIDER_SYNC_STACK_CHILD";
const PROVIDER_STACK_TEST: &str = "daemon::service::task_board_db::provider_sync_execution_isolation_tests::provider_sync_runs_on_fresh_task_stack";
const CONSTRAINED_PROVIDER_STACK: usize = 128 * 1024;

#[test]
fn provider_sync_runs_on_fresh_task_stack() {
    if env::var_os(PROVIDER_STACK_CHILD_ENV).is_none() {
        let inline = run_provider_stack_child("inline");
        assert!(
            !inline.status.success()
                && String::from_utf8_lossy(&inline.stderr).contains("stack overflow"),
            "inline mapping did not reproduce the stack overflow: stdout={} stderr={}",
            String::from_utf8_lossy(&inline.stdout),
            String::from_utf8_lossy(&inline.stderr),
        );
        let isolated = run_provider_stack_child("isolated");
        assert!(
            isolated.status.success(),
            "isolated mapping failed: stdout={} stderr={}",
            String::from_utf8_lossy(&isolated.stdout),
            String::from_utf8_lossy(&isolated.stderr),
        );
        return;
    }

    let mode = env::var(PROVIDER_STACK_CHILD_ENV).expect("provider stack child mode");
    let worker = thread::Builder::new()
        .name("constrained-provider-sync".into())
        .stack_size(CONSTRAINED_PROVIDER_STACK)
        .spawn(move || {
            if mode == "inline" {
                return compile_tracking_regex();
            }
            let runtime = RuntimeBuilder::new_multi_thread()
                .worker_threads(1)
                .enable_all()
                .build()
                .expect("provider sync runtime");
            runtime.block_on(run_provider_sync_task(async { compile_tracking_regex() }))?
        })
        .expect("spawn constrained provider sync");
    worker
        .join()
        .expect("constrained provider sync thread")
        .expect("tracking regex compilation");
}

fn compile_tracking_regex() -> Result<(), harness_kernel::errors::CliError> {
    Regex::new(r"(?i)part of\s+(?:([\w.-]+/[\w.-]+))?#(\d+)")
        .map(|_| ())
        .map_err(|error| {
            harness_kernel::errors::CliErrorKind::workflow_io(format!(
                "compile tracking regex: {error}"
            ))
            .into()
        })
}

fn run_provider_stack_child(mode: &str) -> Output {
    Command::new(env::current_exe().expect("current test executable"))
        .args(["--exact", PROVIDER_STACK_TEST, "--nocapture"])
        .env(PROVIDER_STACK_CHILD_ENV, mode)
        .output()
        .expect("run isolated provider stack test")
}
