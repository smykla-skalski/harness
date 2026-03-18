use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::core_defs::CommandResult;

/// A single build target invocation.
///
/// This keeps the contract generic enough for `make`, `mise`, or any future
/// repo-local build entrypoint while still carrying the common command details
/// the framework needs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildTarget {
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
}

impl BuildTarget {
    #[must_use]
    pub fn make(target: impl Into<String>) -> Self {
        Self {
            program: "make".to_string(),
            args: vec![target.into()],
            cwd: None,
            env: HashMap::new(),
        }
    }

    #[must_use]
    pub fn mise(task: impl Into<String>) -> Self {
        Self {
            program: "mise".to_string(),
            args: vec!["run".to_string(), task.into()],
            cwd: None,
            env: HashMap::new(),
        }
    }
}

/// Generic build-system block.
///
/// The current codebase still shells out directly to repo-local build entry
/// points such as `make` or `mise`. This trait provides the block boundary so
/// command/setup code can depend on a typed contract instead of a hardcoded
/// subprocess call.
pub trait BuildSystem: Send + Sync {
    /// Human-readable block name.
    fn name(&self) -> &'static str {
        "build"
    }

    /// Binaries this block considers direct-use deny-list candidates for hook
    /// policy aggregation.
    fn denied_binaries(&self) -> &'static [&'static str] {
        &[]
    }

    /// Run a build target and capture its output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the underlying command fails.
    fn run_target(&self, target: &BuildTarget) -> Result<CommandResult, BlockError>;

    /// Run a build target while surfacing streaming progress.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the underlying command fails.
    fn run_target_streaming(&self, target: &BuildTarget) -> Result<CommandResult, BlockError>;

    /// Convenience helper for a repo-local target name.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the target fails.
    fn run_named_target(
        &self,
        name: &str,
        cwd: Option<&Path>,
    ) -> Result<CommandResult, BlockError> {
        let mut target = BuildTarget::make(name.to_string());
        target.cwd = cwd.map(|path| path.display().to_string());
        self.run_target(&target)
    }
}

/// Production build-system implementation backed by the process block.
pub struct ProcessBuildSystem {
    process: Arc<dyn ProcessExecutor>,
}

impl ProcessBuildSystem {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }

    fn run_internal(
        &self,
        target: &BuildTarget,
        streaming: bool,
    ) -> Result<CommandResult, BlockError> {
        let mut args = Vec::with_capacity(1 + target.args.len());
        args.push(target.program.as_str());
        args.extend(target.args.iter().map(String::as_str));

        let cwd = target.cwd.as_deref().map(Path::new);
        if streaming {
            self.process
                .run_streaming(&args, cwd, Some(&target.env), &[0])
        } else {
            self.process.run(&args, cwd, Some(&target.env), &[0])
        }
    }
}

impl BuildSystem for ProcessBuildSystem {
    fn run_target(&self, target: &BuildTarget) -> Result<CommandResult, BlockError> {
        self.run_internal(target, false)
    }

    fn run_target_streaming(&self, target: &BuildTarget) -> Result<CommandResult, BlockError> {
        self.run_internal(target, true)
    }
}

#[cfg(test)]
use std::sync;

/// Test fake for `BuildSystem` that records invocations and returns canned results.
#[cfg(test)]
pub struct FakeBuildSystem {
    invocations: sync::Mutex<Vec<BuildTarget>>,
    result_factory: Box<dyn Fn() -> Result<CommandResult, BlockError> + Send + Sync>,
}

#[cfg(test)]
impl FakeBuildSystem {
    #[must_use]
    pub fn success() -> Self {
        Self {
            invocations: sync::Mutex::new(Vec::new()),
            result_factory: Box::new(|| {
                Ok(CommandResult {
                    args: vec![],
                    returncode: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                })
            }),
        }
    }

    #[must_use]
    pub fn with_result(result: CommandResult) -> Self {
        Self {
            invocations: sync::Mutex::new(Vec::new()),
            result_factory: Box::new(move || Ok(result.clone())),
        }
    }

    pub fn invocations(&self) -> Vec<BuildTarget> {
        self.invocations
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .clone()
    }
}

#[cfg(test)]
impl BuildSystem for FakeBuildSystem {
    fn run_target(&self, target: &BuildTarget) -> Result<CommandResult, BlockError> {
        self.invocations
            .lock()
            .unwrap_or_else(sync::PoisonError::into_inner)
            .push(target.clone());
        (self.result_factory)()
    }

    fn run_target_streaming(&self, target: &BuildTarget) -> Result<CommandResult, BlockError> {
        self.run_target(target)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::path::Path;
    use std::sync::Arc;

    use super::*;
    use crate::infra::blocks::{FakeProcessExecutor, FakeProcessMethod, FakeResponse};
    use crate::core_defs::CommandResult;

    fn success_result(args: &[&str]) -> CommandResult {
        CommandResult {
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        }
    }

    #[test]
    fn build_target_make_uses_make_program() {
        let target = BuildTarget::make("check");

        assert_eq!(target.program, "make");
        assert_eq!(target.args, vec!["check"]);
        assert!(target.cwd.is_none());
        assert!(target.env.is_empty());
    }

    #[test]
    fn build_target_mise_uses_mise_run_task() {
        let target = BuildTarget::mise("check");

        assert_eq!(target.program, "mise");
        assert_eq!(target.args, vec!["run", "check"]);
        assert!(target.cwd.is_none());
        assert!(target.env.is_empty());
    }

    #[test]
    fn process_build_system_runs_target_with_process_block() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "make".to_string(),
            expected_args: Some(vec!["make".into(), "check".into()]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["make", "check"])),
        }]));
        let build = ProcessBuildSystem::new(fake);

        let result = build
            .run_target(&BuildTarget::make("check"))
            .expect("expected build target to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn process_build_system_runs_streaming_target_with_process_block() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "mise".to_string(),
            expected_args: Some(vec!["mise".into(), "run".into(), "test".into()]),
            expected_method: Some(FakeProcessMethod::RunStreaming),
            result: Ok(success_result(&["mise", "run", "test"])),
        }]));
        let build = ProcessBuildSystem::new(fake);

        let result = build
            .run_target_streaming(&BuildTarget::mise("test"))
            .expect("expected streaming build target to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn run_named_target_sets_cwd_on_make_target() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "make".to_string(),
            expected_args: Some(vec!["make".into(), "install".into()]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["make", "install"])),
        }]));
        let build = ProcessBuildSystem::new(fake);

        let result = build
            .run_named_target("install", Some(Path::new("/tmp")))
            .expect("expected named target to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn build_target_serializes_roundtrip() {
        let mut env = HashMap::new();
        env.insert("PROFILE".to_string(), "dev".to_string());

        let target = BuildTarget {
            program: "mise".to_string(),
            args: vec!["run".to_string(), "check".to_string()],
            cwd: Some("/repo".to_string()),
            env,
        };

        let json = serde_json::to_string(&target).expect("serialize target");
        let back: BuildTarget = serde_json::from_str(&json).expect("deserialize target");

        assert_eq!(back, target);
    }

    #[test]
    fn build_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<BuildTarget>();
        assert_send_sync::<ProcessBuildSystem>();
    }

    #[test]
    fn fake_build_system_records_invocations() {
        let fake = FakeBuildSystem::success();
        let target = BuildTarget::make("check");
        let result = fake.run_target(&target).expect("should succeed");

        assert_eq!(result.returncode, 0);
        let invocations = fake.invocations();
        assert_eq!(invocations.len(), 1);
        assert_eq!(invocations[0].program, "make");
    }

    #[test]
    fn fake_build_system_returns_custom_result() {
        let custom = CommandResult {
            args: vec!["make".into(), "test".into()],
            returncode: 2,
            stdout: "output".into(),
            stderr: "err".into(),
        };
        let fake = FakeBuildSystem::with_result(custom);
        let result = fake
            .run_target(&BuildTarget::make("test"))
            .expect("should return custom result");
        assert_eq!(result.returncode, 2);
        assert_eq!(result.stdout, "output");
    }

    // -- Contract tests: fake satisfies the same invariants as production --

    mod contracts {
        use super::*;

        fn contract_name_is_non_empty(build: &dyn BuildSystem) {
            assert!(!build.name().is_empty(), "block name should not be empty");
        }

        fn contract_denied_binaries_is_stable(build: &dyn BuildSystem) {
            let first = build.denied_binaries();
            let second = build.denied_binaries();
            assert_eq!(first, second, "denied_binaries should be stable");
        }

        fn contract_run_target_does_not_panic(build: &dyn BuildSystem) {
            let _ = build.run_target(&BuildTarget::make("echo-test"));
        }

        fn contract_run_target_streaming_does_not_panic(build: &dyn BuildSystem) {
            let _ = build.run_target_streaming(&BuildTarget::make("echo-test"));
        }

        #[test]
        fn fake_satisfies_name_is_non_empty() {
            contract_name_is_non_empty(&FakeBuildSystem::success());
        }

        #[test]
        fn fake_satisfies_denied_binaries_is_stable() {
            contract_denied_binaries_is_stable(&FakeBuildSystem::success());
        }

        #[test]
        fn fake_satisfies_run_target_does_not_panic() {
            contract_run_target_does_not_panic(&FakeBuildSystem::success());
        }

        #[test]
        fn fake_satisfies_run_target_streaming_does_not_panic() {
            contract_run_target_streaming_does_not_panic(&FakeBuildSystem::success());
        }
    }
}
