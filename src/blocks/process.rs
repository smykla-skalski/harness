use std::collections::HashMap;
use std::path::Path;
#[cfg(test)]
use std::sync;

use crate::blocks::BlockError;
use crate::core_defs::CommandResult;
use crate::exec;

/// Subprocess execution. The lowest-level block.
///
/// All other blocks that run external commands depend on this trait.
/// Production: `StdProcessExecutor`. Tests: `FakeProcessExecutor`.
pub trait ProcessExecutor: Send + Sync {
    /// Run a command and capture stdout/stderr.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the command fails to start or exits with
    /// a code not in `ok_exit_codes`.
    fn run(
        &self,
        args: &[&str],
        cwd: Option<&Path>,
        env: Option<&HashMap<String, String>>,
        ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError>;

    /// Run a command, stream output with a heartbeat, capture stderr.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the command fails to start or exits with
    /// a code not in `ok_exit_codes`.
    fn run_streaming(
        &self,
        args: &[&str],
        cwd: Option<&Path>,
        env: Option<&HashMap<String, String>>,
        ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError>;

    /// Run a command with inherited stdio (interactive).
    ///
    /// Note: `cwd` and `env` are accepted for interface consistency but
    /// the current implementation does not forward them to the underlying
    /// process. The process inherits the parent's working directory and
    /// environment (plus `merge_env` defaults).
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the command fails to start or exits with
    /// a code not in `ok_exit_codes`.
    fn run_inherited(
        &self,
        args: &[&str],
        cwd: Option<&Path>,
        env: Option<&HashMap<String, String>>,
        ok_exit_codes: &[i32],
    ) -> Result<i32, BlockError>;
}

pub struct StdProcessExecutor;

impl ProcessExecutor for StdProcessExecutor {
    fn run(
        &self,
        args: &[&str],
        cwd: Option<&Path>,
        env: Option<&HashMap<String, String>>,
        ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError> {
        exec::run_command(args, cwd, env, ok_exit_codes)
            .map_err(|e| BlockError::new("process", &command_label(args), e))
    }

    fn run_streaming(
        &self,
        args: &[&str],
        cwd: Option<&Path>,
        env: Option<&HashMap<String, String>>,
        ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError> {
        exec::run_command_streaming(args, cwd, env, ok_exit_codes)
            .map_err(|e| BlockError::new("process", &command_label(args), e))
    }

    fn run_inherited(
        &self,
        args: &[&str],
        _cwd: Option<&Path>,
        _env: Option<&HashMap<String, String>>,
        ok_exit_codes: &[i32],
    ) -> Result<i32, BlockError> {
        exec::run_command_inherited(args, ok_exit_codes)
            .map_err(|e| BlockError::new("process", &command_label(args), e))
    }
}

fn command_label(args: &[&str]) -> String {
    args.iter().take(2).copied().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
pub struct FakeProcessExecutor {
    responses: sync::Mutex<Vec<FakeResponse>>,
    invocations: sync::Mutex<Vec<FakeInvocation>>,
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FakeProcessMethod {
    Run,
    RunStreaming,
    RunInherited,
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeInvocation {
    pub method: FakeProcessMethod,
    pub args: Vec<String>,
}

#[cfg(test)]
pub struct FakeResponse {
    pub expected_program: String,
    pub expected_args: Option<Vec<String>>,
    pub expected_method: Option<FakeProcessMethod>,
    pub result: Result<CommandResult, BlockError>,
}

#[cfg(test)]
impl FakeProcessExecutor {
    #[must_use]
    pub fn new(responses: Vec<FakeResponse>) -> Self {
        Self {
            responses: sync::Mutex::new(responses),
            invocations: sync::Mutex::new(Vec::new()),
        }
    }

    /// Returns recorded invocations.
    ///
    /// # Panics
    /// Panics if the mutex is poisoned.
    #[must_use]
    pub fn invocations(&self) -> Vec<FakeInvocation> {
        self.invocations.lock().expect("lock poisoned").clone()
    }

    fn validate_response(
        response: &FakeResponse,
        method: FakeProcessMethod,
        args: &[&str],
        actual_args: &[String],
    ) {
        if let Some(expected_method) = response.expected_method {
            assert_eq!(
                method, expected_method,
                "FakeProcessExecutor: unexpected method"
            );
        }
        if !response.expected_program.is_empty() {
            let actual = args.first().copied().unwrap_or_default();
            assert_eq!(
                actual, response.expected_program,
                "FakeProcessExecutor: unexpected program"
            );
        }
        if let Some(ref expected_args) = response.expected_args {
            assert_eq!(
                actual_args, expected_args,
                "FakeProcessExecutor: unexpected args"
            );
        }
    }

    fn next_response(
        &self,
        method: FakeProcessMethod,
        args: &[&str],
    ) -> Result<CommandResult, BlockError> {
        let actual_args: Vec<String> = args.iter().map(|arg| (*arg).to_string()).collect();
        self.invocations
            .lock()
            .expect("lock poisoned")
            .push(FakeInvocation {
                method,
                args: actual_args.clone(),
            });
        let mut responses = self.responses.lock().expect("lock poisoned");
        assert!(
            !responses.is_empty(),
            "FakeProcessExecutor: no responses left"
        );
        let response = responses.remove(0);
        Self::validate_response(&response, method, args, &actual_args);
        response.result
    }
}

#[cfg(test)]
impl ProcessExecutor for FakeProcessExecutor {
    fn run(
        &self,
        args: &[&str],
        _cwd: Option<&Path>,
        _env: Option<&HashMap<String, String>>,
        _ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError> {
        self.next_response(FakeProcessMethod::Run, args)
    }

    fn run_streaming(
        &self,
        args: &[&str],
        _cwd: Option<&Path>,
        _env: Option<&HashMap<String, String>>,
        _ok_exit_codes: &[i32],
    ) -> Result<CommandResult, BlockError> {
        self.next_response(FakeProcessMethod::RunStreaming, args)
    }

    fn run_inherited(
        &self,
        args: &[&str],
        _cwd: Option<&Path>,
        _env: Option<&HashMap<String, String>>,
        _ok_exit_codes: &[i32],
    ) -> Result<i32, BlockError> {
        let result = self.next_response(FakeProcessMethod::RunInherited, args)?;
        Ok(result.returncode)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
