use std::sync;

use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

use super::contract::{BuildSystem, BuildTarget};

/// Test fake for `BuildSystem` that records invocations and returns canned results.
pub struct FakeBuildSystem {
    invocations: sync::Mutex<Vec<BuildTarget>>,
    result_factory: Box<dyn Fn() -> Result<CommandResult, BlockError> + Send + Sync>,
}

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
