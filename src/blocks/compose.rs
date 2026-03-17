use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use crate::blocks::{BlockError, ProcessExecutor};
use crate::core_defs::CommandResult;

/// Multi-container orchestration via docker compose.
pub trait ComposeOrchestrator: Send + Sync {
    /// Start a compose project from a file.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the compose command fails.
    fn up(
        &self,
        compose_file: &Path,
        project_name: &str,
        wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError>;

    /// Stop a compose project and remove volumes.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the compose command fails.
    fn down(&self, compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError>;

    /// Stop a compose project by name only.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the compose command fails.
    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError>;
}

/// Production compose implementation backed by `docker compose`.
pub struct DockerComposeOrchestrator {
    process: Arc<dyn ProcessExecutor>,
}

impl DockerComposeOrchestrator {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }
}

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

#[cfg(test)]
#[derive(Debug, Default)]
pub struct FakeComposeOrchestrator {
    projects: std::sync::Mutex<std::collections::HashMap<String, bool>>,
}

#[cfg(test)]
impl FakeComposeOrchestrator {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[cfg(test)]
impl ComposeOrchestrator for FakeComposeOrchestrator {
    fn up(
        &self,
        _compose_file: &Path,
        project_name: &str,
        _wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError> {
        let mut projects = self.projects.lock().expect("lock poisoned");
        projects.insert(project_name.to_string(), true);
        Ok(CommandResult {
            args: vec!["docker".into(), "compose".into(), "up".into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn down(&self, _compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError> {
        let mut projects = self.projects.lock().expect("lock poisoned");
        projects.remove(project_name);
        Ok(CommandResult {
            args: vec!["docker".into(), "compose".into(), "down".into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError> {
        let mut projects = self.projects.lock().expect("lock poisoned");
        projects.remove(project_name);
        Ok(CommandResult {
            args: vec!["docker".into(), "compose".into(), "down".into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::Arc;

    use super::*;
    use crate::blocks::{
        FakeComposeOrchestrator, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
    };

    fn success_result(args: &[&str]) -> CommandResult {
        CommandResult {
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        }
    }

    #[test]
    fn docker_compose_orchestrator_up_uses_streaming_compose_command() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-f".into(),
                "/tmp/compose.yml".into(),
                "-p".into(),
                "mesh".into(),
                "up".into(),
                "-d".into(),
                "--wait".into(),
                "--wait-timeout".into(),
                "90".into(),
            ]),
            expected_method: Some(FakeProcessMethod::RunStreaming),
            result: Ok(success_result(&[
                "docker",
                "compose",
                "-f",
                "/tmp/compose.yml",
                "-p",
                "mesh",
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                "90",
            ])),
        }]));
        let orchestrator = DockerComposeOrchestrator::new(fake);

        let result = orchestrator
            .up(
                Path::new("/tmp/compose.yml"),
                "mesh",
                Duration::from_secs(90),
            )
            .expect("expected compose up to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn docker_compose_orchestrator_down_includes_volume_removal() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-f".into(),
                "/tmp/compose.yml".into(),
                "-p".into(),
                "mesh".into(),
                "down".into(),
                "-v".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&[
                "docker",
                "compose",
                "-f",
                "/tmp/compose.yml",
                "-p",
                "mesh",
                "down",
                "-v",
            ])),
        }]));
        let orchestrator = DockerComposeOrchestrator::new(fake);

        let result = orchestrator
            .down(Path::new("/tmp/compose.yml"), "mesh")
            .expect("expected compose down to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn docker_compose_orchestrator_down_project_works_without_file() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-p".into(),
                "mesh".into(),
                "down".into(),
                "-v".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&[
                "docker", "compose", "-p", "mesh", "down", "-v",
            ])),
        }]));
        let orchestrator = DockerComposeOrchestrator::new(fake);

        let result = orchestrator
            .down_project("mesh")
            .expect("expected compose down to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn fake_compose_orchestrator_tracks_project_state() {
        let orchestrator = FakeComposeOrchestrator::new();

        orchestrator
            .up(
                Path::new("/tmp/compose.yml"),
                "mesh",
                Duration::from_secs(60),
            )
            .expect("expected fake up to succeed");
        assert!(
            orchestrator
                .projects
                .lock()
                .expect("lock poisoned")
                .contains_key("mesh")
        );

        orchestrator
            .down_project("mesh")
            .expect("expected fake down to succeed");
        assert!(
            !orchestrator
                .projects
                .lock()
                .expect("lock poisoned")
                .contains_key("mesh")
        );
    }

    #[test]
    fn compose_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<DockerComposeOrchestrator>();
        assert_send_sync::<FakeComposeOrchestrator>();
    }
}
