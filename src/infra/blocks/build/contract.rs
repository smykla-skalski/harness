use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

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

/// Generic build block.
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
