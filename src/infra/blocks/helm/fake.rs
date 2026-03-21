use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

use super::{HelmSetting, PackageDeployResult, PackageDeployer};

#[derive(Debug, Default)]
pub struct FakePackageDeployer {
    pub(crate) targets: Mutex<Vec<String>>,
    pub(crate) releases: Mutex<HashMap<String, Vec<HelmSetting>>>,
}

impl FakePackageDeployer {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

impl PackageDeployer for FakePackageDeployer {
    fn run_target(
        &self,
        _repo_root: &Path,
        target: &str,
        _env: &HashMap<String, String>,
    ) -> Result<CommandResult, BlockError> {
        self.targets
            .lock()
            .expect("lock poisoned")
            .push(target.to_string());
        Ok(CommandResult {
            args: vec!["make".into(), target.into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn run_target_live(
        &self,
        _repo_root: &Path,
        target: &str,
        _env: &HashMap<String, String>,
    ) -> Result<i32, BlockError> {
        self.targets
            .lock()
            .expect("lock poisoned")
            .push(format!("live:{target}"));
        Ok(0)
    }

    fn upgrade_install(
        &self,
        release: &str,
        chart: &str,
        namespace: Option<&str>,
        settings: &[HelmSetting],
        _extra_args: &[&str],
    ) -> Result<PackageDeployResult, BlockError> {
        self.releases
            .lock()
            .expect("lock poisoned")
            .insert(release.to_string(), settings.to_vec());
        Ok(PackageDeployResult {
            release: release.to_string(),
            namespace: namespace.map(ToOwned::to_owned),
            chart: chart.to_string(),
            applied_settings: settings.to_vec(),
            command: CommandResult {
                args: vec![
                    "helm".into(),
                    "upgrade".into(),
                    "--install".into(),
                    release.into(),
                    chart.into(),
                ],
                returncode: 0,
                stdout: String::new(),
                stderr: String::new(),
            },
        })
    }

    fn uninstall(
        &self,
        release: &str,
        _namespace: Option<&str>,
        _extra_args: &[&str],
    ) -> Result<CommandResult, BlockError> {
        self.releases.lock().expect("lock poisoned").remove(release);
        Ok(CommandResult {
            args: vec!["helm".into(), "uninstall".into(), release.into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }
}
