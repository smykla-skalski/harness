use std::collections;
use std::path::Path;
use std::sync;
use std::time::Duration;

use super::ComposeOrchestrator;
use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

#[derive(Debug, Default)]
pub struct FakeComposeOrchestrator {
    pub(crate) projects: sync::Mutex<collections::HashMap<String, bool>>,
}

impl FakeComposeOrchestrator {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

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
