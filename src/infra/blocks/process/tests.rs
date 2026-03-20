use std::collections::HashMap;
use std::path::Path;

use crate::infra::blocks::BlockError;
use crate::infra::blocks::process as process_block;
use crate::infra::exec::CommandResult;

use super::{FakeProcessExecutor, FakeResponse, ProcessExecutor, StdProcessExecutor};

#[test]
fn std_process_executor_run_echo() {
    let executor = StdProcessExecutor;
    let result = executor
        .run(&["echo", "hello"], None, None, &[0])
        .expect("expected success");
    assert_eq!(result.returncode, 0);
    assert_eq!(result.stdout, "hello\n");
}

#[test]
fn std_process_executor_run_fails_on_bad_exit() {
    let executor = StdProcessExecutor;
    let result = executor.run(&["false"], None, None, &[0]);
    assert!(result.is_err());
}

#[test]
fn std_process_executor_run_with_cwd() {
    let executor = StdProcessExecutor;
    let result = executor
        .run(&["pwd"], Some(Path::new("/tmp")), None, &[0])
        .expect("expected success");
    assert!(result.stdout.trim_end().ends_with("/tmp"));
}

#[test]
fn std_process_executor_run_with_env() {
    let executor = StdProcessExecutor;
    let mut env = HashMap::new();
    env.insert("TEST_VAR".to_string(), "value".to_string());
    let result = executor
        .run(&["sh", "-c", "echo $TEST_VAR"], None, Some(&env), &[0])
        .expect("expected success");
    assert_eq!(result.stdout.trim_end(), "value");
}

#[test]
fn fake_process_executor_returns_canned_response() {
    let fake = FakeProcessExecutor::new(vec![FakeResponse {
        expected_program: "echo".to_string(),
        expected_args: None,
        expected_method: None,
        result: Ok(CommandResult {
            args: vec!["echo".to_string(), "hello".to_string()],
            returncode: 0,
            stdout: "hello\n".to_string(),
            stderr: String::new(),
        }),
    }]);
    let result = fake
        .run(&["echo", "hello"], None, None, &[0])
        .expect("expected success");
    assert_eq!(result.stdout, "hello\n");
}

#[test]
#[should_panic(expected = "FakeProcessExecutor: no responses left")]
fn fake_process_executor_panics_when_exhausted() {
    let fake = FakeProcessExecutor::new(vec![]);
    let _ = fake.run(&["echo", "hello"], None, None, &[0]);
}

#[test]
fn fake_process_executor_is_send_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<FakeProcessExecutor>();
}

mod contracts {
    use super::*;

    fn contract_run_returns_output(executor: &dyn ProcessExecutor) {
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

    fn contract_run_rejects_bad_exit_code(executor: &dyn ProcessExecutor) {
        let result = executor.run(&["false"], None, None, &[0]);
        assert!(result.is_err(), "false should fail with exit code 1");
    }

    fn contract_run_streaming_returns_output(executor: &dyn ProcessExecutor) {
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

    fn contract_run_inherited_returns_exit_code(executor: &dyn ProcessExecutor) {
        let code = executor
            .run_inherited(&["true"], None, None, &[0])
            .expect("true should succeed");
        assert_eq!(code, 0);
    }

    #[test]
    fn fake_satisfies_run_returns_output() {
        let fake = process_block::FakeProcessExecutor::new(vec![process_block::FakeResponse {
            expected_program: "echo".to_string(),
            expected_args: None,
            expected_method: None,
            result: Ok(CommandResult {
                args: vec!["echo".to_string(), "hello".to_string()],
                returncode: 0,
                stdout: "hello\n".to_string(),
                stderr: String::new(),
            }),
        }]);
        contract_run_returns_output(&fake);
    }

    #[test]
    fn fake_satisfies_run_rejects_bad_exit_code() {
        let fake = process_block::FakeProcessExecutor::new(vec![process_block::FakeResponse {
            expected_program: "false".to_string(),
            expected_args: None,
            expected_method: None,
            result: Err(BlockError::message("process", "false", "exit code 1")),
        }]);
        contract_run_rejects_bad_exit_code(&fake);
    }

    #[test]
    fn fake_satisfies_run_streaming_returns_output() {
        let fake = process_block::FakeProcessExecutor::new(vec![process_block::FakeResponse {
            expected_program: "echo".to_string(),
            expected_args: None,
            expected_method: None,
            result: Ok(CommandResult {
                args: vec!["echo".to_string(), "stream".to_string()],
                returncode: 0,
                stdout: "stream\n".to_string(),
                stderr: String::new(),
            }),
        }]);
        contract_run_streaming_returns_output(&fake);
    }

    #[test]
    fn fake_satisfies_run_inherited_returns_exit_code() {
        let fake = process_block::FakeProcessExecutor::new(vec![process_block::FakeResponse {
            expected_program: "true".to_string(),
            expected_args: None,
            expected_method: None,
            result: Ok(CommandResult {
                args: vec!["true".to_string()],
                returncode: 0,
                stdout: String::new(),
                stderr: String::new(),
            }),
        }]);
        contract_run_inherited_returns_exit_code(&fake);
    }

    #[test]
    #[ignore = "needs real system binaries"]
    fn production_satisfies_run_returns_output() {
        contract_run_returns_output(&process_block::StdProcessExecutor);
    }

    #[test]
    #[ignore = "needs real system binaries"]
    fn production_satisfies_run_rejects_bad_exit_code() {
        contract_run_rejects_bad_exit_code(&process_block::StdProcessExecutor);
    }

    #[test]
    #[ignore = "needs real system binaries"]
    fn production_satisfies_run_streaming_returns_output() {
        contract_run_streaming_returns_output(&process_block::StdProcessExecutor);
    }

    #[test]
    #[ignore = "needs real system binaries"]
    fn production_satisfies_run_inherited_returns_exit_code() {
        contract_run_inherited_returns_exit_code(&process_block::StdProcessExecutor);
    }
}
