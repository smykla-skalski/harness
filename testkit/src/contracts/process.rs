use harness::infra::blocks::ProcessExecutor;

/// A successful `run` with `echo` returns exit code 0 and the echoed text.
///
/// # Panics
/// Panics if the executor fails or returns unexpected output.
pub fn contract_run_returns_output(executor: &dyn ProcessExecutor) {
    let result = executor
        .run(&["echo", "hello"], None, None, &[0])
        .expect("echo should succeed");
    assert_eq!(result.returncode, 0);
    assert!(
        result.stdout.contains("hello"),
        "stdout should contain 'hello', got: {:?}",
        result.stdout
    );
}

/// Running a command that exits with a non-zero code not in `ok_exit_codes`
/// returns an error.
///
/// # Panics
/// Panics if the executor does not reject the bad exit code.
pub fn contract_run_rejects_bad_exit_code(executor: &dyn ProcessExecutor) {
    let result = executor.run(&["false"], None, None, &[0]);
    assert!(result.is_err(), "false should fail with exit code 1");
}

/// Running a command that exits non-zero but is listed in `ok_exit_codes`
/// succeeds.
///
/// # Panics
/// Panics if the executor fails or returns an unexpected exit code.
pub fn contract_run_accepts_listed_exit_code(executor: &dyn ProcessExecutor) {
    let result = executor
        .run(&["false"], None, None, &[0, 1])
        .expect("false with ok_exit_codes=[0,1] should succeed");
    assert_eq!(result.returncode, 1);
}

/// `run_streaming` returns the same output as `run` for simple commands.
///
/// # Panics
/// Panics if the executor fails or returns unexpected output.
pub fn contract_run_streaming_returns_output(executor: &dyn ProcessExecutor) {
    let result = executor
        .run_streaming(&["echo", "stream"], None, None, &[0])
        .expect("streaming echo should succeed");
    assert_eq!(result.returncode, 0);
    assert!(
        result.stdout.contains("stream"),
        "stdout should contain 'stream', got: {:?}",
        result.stdout
    );
}

/// `run_inherited` returns the exit code of the child process.
///
/// # Panics
/// Panics if the executor fails or returns an unexpected exit code.
pub fn contract_run_inherited_returns_exit_code(executor: &dyn ProcessExecutor) {
    let code = executor
        .run_inherited(&["true"], None, None, &[0])
        .expect("true should succeed");
    assert_eq!(code, 0);
}

#[cfg(test)]
mod tests {
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
}
