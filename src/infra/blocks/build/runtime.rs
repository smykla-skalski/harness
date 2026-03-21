use std::path::Path;
use std::sync::Arc;

use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::infra::exec::CommandResult;

use super::contract::{BuildSystem, BuildTarget};

/// Production build implementation backed by the process block.
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
