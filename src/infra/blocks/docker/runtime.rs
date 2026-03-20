use std::io::Write as _;
use std::sync::Arc;

use tempfile::NamedTempFile;

use super::{ContainerConfig, ContainerRuntime};
use crate::infra::blocks::{BlockError, ProcessExecutor};
use crate::infra::exec::CommandResult;

/// Production container runtime backed by the docker CLI.
pub struct DockerContainerRuntime {
    process: Arc<dyn ProcessExecutor>,
}

impl DockerContainerRuntime {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }

    fn docker(&self, args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, BlockError> {
        let mut command: Vec<&str> = vec!["docker"];
        command.extend_from_slice(args);
        self.process.run(&command, None, None, ok_exit_codes)
    }
}

impl ContainerRuntime for DockerContainerRuntime {
    fn run_detached(&self, config: &ContainerConfig) -> Result<CommandResult, BlockError> {
        let mut args: Vec<String> = vec![
            "run".into(),
            "-d".into(),
            "--name".into(),
            config.name.clone(),
            "--network".into(),
            config.network.clone(),
        ];
        for (key, value) in &config.env {
            args.push("-e".into());
            args.push(format!("{key}={value}"));
        }
        for (host, container) in &config.ports {
            args.push("-p".into());
            args.push(format!("{host}:{container}"));
        }
        for (key, value) in &config.labels {
            args.push("--label".into());
            args.push(format!("{key}={value}"));
        }
        args.extend(config.extra_args.iter().cloned());
        args.push(config.image.clone());
        args.extend(config.command.iter().cloned());
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.docker(&refs, &[0])
    }

    fn remove(&self, name: &str) -> Result<CommandResult, BlockError> {
        self.docker(&["rm", "-f", name], &[0, 1])
    }

    fn remove_by_label(&self, label: &str) -> Result<Vec<String>, BlockError> {
        let filter_arg = format!("label={label}");
        let result = self.docker(
            &[
                "ps",
                "-a",
                "--filter",
                &filter_arg,
                "--format",
                "{{.Names}}",
            ],
            &[0],
        )?;
        let names: Vec<String> = result
            .stdout
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| line.trim().to_string())
            .collect();
        for name in &names {
            self.remove(name)?;
        }
        Ok(names)
    }

    fn is_running(&self, name: &str) -> Result<bool, BlockError> {
        let result = self.docker(&["inspect", "-f", "{{.State.Running}}", name], &[0, 1])?;
        Ok(result.returncode == 0 && result.stdout.trim() == "true")
    }

    fn inspect_ip(&self, container: &str, network: &str) -> Result<String, BlockError> {
        let format_str =
            format!("{{{{(index .NetworkSettings.Networks \"{network}\").IPAddress}}}}");
        let result = self.docker(&["inspect", "-f", &format_str, container], &[0])?;
        let ip = result.stdout.trim().to_string();
        if ip.is_empty() {
            return Err(BlockError::message(
                "docker",
                &format!("inspect_ip {container}"),
                format!("no IP on network {network}"),
            ));
        }
        Ok(ip)
    }

    fn list_formatted(
        &self,
        filter_args: &[&str],
        format_template: &str,
    ) -> Result<CommandResult, BlockError> {
        let mut args = vec!["ps"];
        args.extend_from_slice(filter_args);
        args.push("--format");
        args.push(format_template);
        self.docker(&args, &[0])
    }

    fn exec_command(&self, container: &str, command: &[&str]) -> Result<CommandResult, BlockError> {
        let mut args: Vec<&str> = vec!["exec", container];
        args.extend_from_slice(command);
        self.docker(&args, &[0])
    }

    fn exec_detached(
        &self,
        container: &str,
        command: &[&str],
    ) -> Result<CommandResult, BlockError> {
        let mut args: Vec<&str> = vec!["exec", "-d", container];
        args.extend_from_slice(command);
        self.docker(&args, &[0])
    }

    fn write_file(&self, container: &str, path: &str, content: &str) -> Result<(), BlockError> {
        let mut tmp = NamedTempFile::new()
            .map_err(|error| BlockError::new("docker", "write_file temp", error))?;
        tmp.write_all(content.as_bytes())
            .map_err(|error| BlockError::new("docker", "write_file", error))?;
        let src = tmp.path().to_string_lossy().into_owned();
        let dest = format!("{container}:{path}");
        self.docker(&["cp", &src, &dest], &[0])?;
        Ok(())
    }

    fn create_network(&self, name: &str, subnet: &str) -> Result<(), BlockError> {
        let filter = format!("name=^{name}$");
        let result = self.docker(
            &[
                "network",
                "ls",
                "--filter",
                &filter,
                "--format",
                "{{.Name}}",
            ],
            &[0],
        )?;
        if result.stdout.trim() == name {
            return Ok(());
        }
        self.docker(&["network", "create", "--subnet", subnet, name], &[0])?;
        Ok(())
    }

    fn remove_network(&self, name: &str) -> Result<(), BlockError> {
        self.docker(&["network", "rm", name], &[0, 1])?;
        Ok(())
    }

    fn logs(&self, container: &str, args: &[&str]) -> Result<CommandResult, BlockError> {
        let mut full_args: Vec<&str> = vec!["logs"];
        full_args.extend_from_slice(args);
        full_args.push(container);
        self.docker(&full_args, &[0])
    }

    fn logs_follow(&self, container: &str, args: &[&str]) -> Result<i32, BlockError> {
        let mut full_args = vec!["docker".to_string(), "logs".to_string()];
        full_args.extend(args.iter().map(|arg| (*arg).to_string()));
        full_args.push(container.to_string());
        let refs: Vec<&str> = full_args.iter().map(String::as_str).collect();
        self.process.run_inherited(&refs, None, None, &[0])
    }
}
