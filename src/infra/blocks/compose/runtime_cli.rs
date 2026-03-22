use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use super::ComposeOrchestrator;
use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::infra::exec::CommandResult;

/// Production compose implementation backed by `docker compose`.
#[cfg(feature = "compose")]
pub struct DockerComposeOrchestrator {
    process: Arc<dyn ProcessExecutor>,
}

#[cfg(feature = "compose")]
impl DockerComposeOrchestrator {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }
}

#[cfg(feature = "compose")]
impl ComposeOrchestrator for DockerComposeOrchestrator {
    fn up(
        &self,
        compose_file: &Path,
        project_name: &str,
        wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError> {
        let file_str = compose_file.to_string_lossy();
        let timeout_str = wait_timeout.as_secs().to_string();
        self.process.run_streaming(
            &[
                "docker",
                "compose",
                "-f",
                &file_str,
                "-p",
                project_name,
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                &timeout_str,
            ],
            None,
            None,
            &[0],
        )
    }

    fn down(&self, compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError> {
        let file_str = compose_file.to_string_lossy();
        self.process.run(
            &[
                "docker",
                "compose",
                "-f",
                &file_str,
                "-p",
                project_name,
                "down",
                "-v",
            ],
            None,
            None,
            &[0],
        )
    }

    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError> {
        self.process.run(
            &["docker", "compose", "-p", project_name, "down", "-v"],
            None,
            None,
            &[0],
        )
    }
}
