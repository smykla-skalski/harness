use std::io::Write as _;
use std::sync::Arc;

use tempfile::NamedTempFile;

use crate::core_defs::CommandResult;
use crate::infra::blocks::{BlockError, ProcessExecutor};

#[cfg(test)]
use std::collections::{HashMap, HashSet};
#[cfg(test)]
use std::sync;

/// Configuration for starting a detached container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerConfig {
    pub image: String,
    pub name: String,
    pub network: String,
    pub env: Vec<(String, String)>,
    pub ports: Vec<(u16, u16)>,
    pub labels: Vec<(String, String)>,
    pub extra_args: Vec<String>,
    pub command: Vec<String>,
}

/// Snapshot of a container from formatted `docker ps` output.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ContainerSnapshot {
    pub id: Option<String>,
    pub image: Option<String>,
    pub name: Option<String>,
    pub status: Option<String>,
    pub networks: Option<String>,
}

/// Container runtime operations.
pub trait ContainerRuntime: Send + Sync {
    /// Start a detached container.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn run_detached(&self, config: &ContainerConfig) -> Result<CommandResult, BlockError>;

    /// Stop and remove a container by name.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn remove(&self, name: &str) -> Result<CommandResult, BlockError>;

    /// Remove all containers matching a label.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if listing or removal fails.
    fn remove_by_label(&self, label: &str) -> Result<Vec<String>, BlockError>;

    /// Check whether a named container is running.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the inspect command fails.
    fn is_running(&self, name: &str) -> Result<bool, BlockError>;

    /// Get a container IP for a specific network.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the container has no IP on that network.
    fn inspect_ip(&self, container: &str, network: &str) -> Result<String, BlockError>;

    /// List containers using formatted `docker ps` output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the list command fails.
    fn list_formatted(
        &self,
        filter_args: &[&str],
        format_template: &str,
    ) -> Result<CommandResult, BlockError>;

    /// Run a command inside a container and capture output.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn exec_command(&self, container: &str, command: &[&str]) -> Result<CommandResult, BlockError>;

    /// Run a command inside a container in detached mode.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn exec_detached(&self, container: &str, command: &[&str])
    -> Result<CommandResult, BlockError>;

    /// Copy file content into a container.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the temp-file write or `docker cp` fails.
    fn write_file(&self, container: &str, path: &str, content: &str) -> Result<(), BlockError>;

    /// Create a Docker network if it does not already exist.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn create_network(&self, name: &str, subnet: &str) -> Result<(), BlockError>;

    /// Remove a Docker network.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn remove_network(&self, name: &str) -> Result<(), BlockError>;

    /// Get container logs.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn logs(&self, container: &str, args: &[&str]) -> Result<CommandResult, BlockError>;

    /// Follow container logs using inherited stdio.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the docker command fails.
    fn logs_follow(&self, container: &str, args: &[&str]) -> Result<i32, BlockError>;
}

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

#[cfg(test)]
#[derive(Debug, Clone)]
struct FakeContainer {
    id: String,
    image: String,
    running: bool,
    ip: String,
    network: String,
    labels: HashMap<String, String>,
    files: HashMap<String, String>,
    logs: String,
}

#[cfg(test)]
#[derive(Debug, Default)]
pub struct FakeContainerRuntime {
    containers: sync::Mutex<HashMap<String, FakeContainer>>,
    networks: sync::Mutex<HashSet<String>>,
}

#[cfg(test)]
impl FakeContainerRuntime {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[cfg(test)]
impl ContainerRuntime for FakeContainerRuntime {
    fn run_detached(&self, config: &ContainerConfig) -> Result<CommandResult, BlockError> {
        let mut containers = self.containers.lock().expect("lock poisoned");
        let next_id = containers.len() + 1;
        let labels = config.labels.iter().cloned().collect::<HashMap<_, _>>();
        let container = FakeContainer {
            id: format!("fake-container-{next_id}"),
            image: config.image.clone(),
            running: true,
            ip: format!("172.18.0.{}", next_id + 1),
            network: config.network.clone(),
            labels,
            files: HashMap::new(),
            logs: String::new(),
        };
        containers.insert(config.name.clone(), container);
        self.networks
            .lock()
            .expect("lock poisoned")
            .insert(config.network.clone());
        Ok(CommandResult {
            args: vec!["docker".into(), "run".into(), "-d".into()],
            returncode: 0,
            stdout: format!("fake-container-{next_id}\n"),
            stderr: String::new(),
        })
    }

    fn remove(&self, name: &str) -> Result<CommandResult, BlockError> {
        self.containers.lock().expect("lock poisoned").remove(name);
        Ok(CommandResult {
            args: vec!["docker".into(), "rm".into(), "-f".into(), name.to_string()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn remove_by_label(&self, label: &str) -> Result<Vec<String>, BlockError> {
        let names = {
            let containers = self.containers.lock().expect("lock poisoned");
            containers
                .iter()
                .filter_map(|(name, container)| {
                    if label_matches(&container.labels, label) {
                        Some(name.clone())
                    } else {
                        None
                    }
                })
                .collect::<Vec<_>>()
        };
        for name in &names {
            self.remove(name)?;
        }
        Ok(names)
    }

    fn is_running(&self, name: &str) -> Result<bool, BlockError> {
        Ok(self
            .containers
            .lock()
            .expect("lock poisoned")
            .get(name)
            .is_some_and(|container| container.running))
    }

    fn inspect_ip(&self, container: &str, network: &str) -> Result<String, BlockError> {
        let containers = self.containers.lock().expect("lock poisoned");
        let Some(found) = containers.get(container) else {
            return Err(BlockError::message(
                "docker",
                &format!("inspect_ip {container}"),
                format!("no IP on network {network}"),
            ));
        };
        if found.network != network || found.ip.is_empty() {
            return Err(BlockError::message(
                "docker",
                &format!("inspect_ip {container}"),
                format!("no IP on network {network}"),
            ));
        }
        Ok(found.ip.clone())
    }

    fn list_formatted(
        &self,
        filter_args: &[&str],
        format_template: &str,
    ) -> Result<CommandResult, BlockError> {
        let label_filter = parse_label_filter(filter_args);
        let containers = self.containers.lock().expect("lock poisoned");
        let stdout = containers
            .iter()
            .filter(|(_, container)| {
                label_filter
                    .as_deref()
                    .is_none_or(|label| label_matches(&container.labels, label))
            })
            .map(|(name, container)| match format_template {
                "{{.ID}}" => container.id.clone(),
                "{{.Image}}" => container.image.clone(),
                "{{.Names}}\t{{.Status}}" => format!(
                    "{name}\t{}",
                    if container.running {
                        "running"
                    } else {
                        "exited"
                    }
                ),
                "{{.Status}}" => {
                    if container.running {
                        "running".to_string()
                    } else {
                        "exited".to_string()
                    }
                }
                "{{.Networks}}" => container.network.clone(),
                "{{json .}}" => serde_json::json!({
                    "ID": container.id,
                    "Image": container.image,
                    "Names": name,
                    "Status": if container.running { "running" } else { "exited" },
                    "Networks": container.network,
                })
                .to_string(),
                _ => name.clone(),
            })
            .collect::<Vec<_>>()
            .join("\n");
        Ok(CommandResult {
            args: vec!["docker".into(), "ps".into(), "-a".into(), "--format".into()],
            returncode: 0,
            stdout,
            stderr: String::new(),
        })
    }

    fn exec_command(&self, container: &str, command: &[&str]) -> Result<CommandResult, BlockError> {
        if !self
            .containers
            .lock()
            .expect("lock poisoned")
            .contains_key(container)
        {
            return Err(BlockError::message(
                "docker",
                &format!("exec_command {container}"),
                "container not found",
            ));
        }
        let mut args = vec![
            "docker".to_string(),
            "exec".to_string(),
            container.to_string(),
        ];
        args.extend(command.iter().map(|arg| (*arg).to_string()));
        Ok(CommandResult {
            args,
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn exec_detached(
        &self,
        container: &str,
        command: &[&str],
    ) -> Result<CommandResult, BlockError> {
        if !self
            .containers
            .lock()
            .expect("lock poisoned")
            .contains_key(container)
        {
            return Err(BlockError::message(
                "docker",
                &format!("exec_detached {container}"),
                "container not found",
            ));
        }
        let mut args = vec![
            "docker".to_string(),
            "exec".to_string(),
            "-d".to_string(),
            container.to_string(),
        ];
        args.extend(command.iter().map(|arg| (*arg).to_string()));
        Ok(CommandResult {
            args,
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn write_file(&self, container: &str, path: &str, content: &str) -> Result<(), BlockError> {
        let mut containers = self.containers.lock().expect("lock poisoned");
        let Some(found) = containers.get_mut(container) else {
            return Err(BlockError::message(
                "docker",
                &format!("write_file {container}"),
                "container not found",
            ));
        };
        found.files.insert(path.to_string(), content.to_string());
        Ok(())
    }

    fn create_network(&self, name: &str, _subnet: &str) -> Result<(), BlockError> {
        self.networks
            .lock()
            .expect("lock poisoned")
            .insert(name.to_string());
        Ok(())
    }

    fn remove_network(&self, name: &str) -> Result<(), BlockError> {
        self.networks.lock().expect("lock poisoned").remove(name);
        Ok(())
    }

    fn logs(&self, container: &str, args: &[&str]) -> Result<CommandResult, BlockError> {
        let containers = self.containers.lock().expect("lock poisoned");
        let Some(found) = containers.get(container) else {
            return Err(BlockError::message(
                "docker",
                &format!("logs {container}"),
                "container not found",
            ));
        };
        let mut command_args = vec!["docker".to_string(), "logs".to_string()];
        command_args.extend(args.iter().map(|arg| (*arg).to_string()));
        command_args.push(container.to_string());
        Ok(CommandResult {
            args: command_args,
            returncode: 0,
            stdout: found.logs.clone(),
            stderr: String::new(),
        })
    }

    fn logs_follow(&self, container: &str, _args: &[&str]) -> Result<i32, BlockError> {
        if !self
            .containers
            .lock()
            .expect("lock poisoned")
            .contains_key(container)
        {
            return Err(BlockError::message(
                "docker",
                &format!("logs_follow {container}"),
                "container not found",
            ));
        }
        Ok(0)
    }
}

#[cfg(test)]
fn label_matches(labels: &HashMap<String, String>, label: &str) -> bool {
    let Some((key, expected)) = label.split_once('=') else {
        return labels.contains_key(label);
    };
    labels.get(key).is_some_and(|actual| actual == expected)
}

#[cfg(test)]
fn parse_label_filter(filter_args: &[&str]) -> Option<String> {
    let mut args = filter_args.iter();
    while let Some(arg) = args.next() {
        if *arg == "--filter"
            && let Some(value) = args.next()
            && let Some(label) = value.strip_prefix("label=")
        {
            return Some(label.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::infra::blocks::{
        FakeContainerRuntime, FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
    };

    fn success_result(args: &[&str], stdout: &str) -> CommandResult {
        CommandResult {
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            returncode: 0,
            stdout: stdout.to_string(),
            stderr: String::new(),
        }
    }

    fn sample_config() -> ContainerConfig {
        ContainerConfig {
            image: "example:latest".to_string(),
            name: "example".to_string(),
            network: "mesh-net".to_string(),
            env: vec![("MODE".to_string(), "test".to_string())],
            ports: vec![(8080, 80)],
            labels: vec![("suite".to_string(), "mesh".to_string())],
            extra_args: vec!["--restart".to_string(), "unless-stopped".to_string()],
            command: vec!["server".to_string()],
        }
    }

    fn last_invocation(fake: &FakeProcessExecutor) -> FakeInvocation {
        fake.invocations()
            .into_iter()
            .last()
            .expect("expected at least one invocation")
    }

    #[test]
    fn docker_container_runtime_run_detached_builds_expected_command() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "run".into(),
                "-d".into(),
                "--name".into(),
                "example".into(),
                "--network".into(),
                "mesh-net".into(),
                "-e".into(),
                "MODE=test".into(),
                "-p".into(),
                "8080:80".into(),
                "--label".into(),
                "suite=mesh".into(),
                "--restart".into(),
                "unless-stopped".into(),
                "example:latest".into(),
                "server".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &[
                    "docker",
                    "run",
                    "-d",
                    "--name",
                    "example",
                    "--network",
                    "mesh-net",
                    "-e",
                    "MODE=test",
                    "-p",
                    "8080:80",
                    "--label",
                    "suite=mesh",
                    "--restart",
                    "unless-stopped",
                    "example:latest",
                    "server",
                ],
                "container-id\n",
            )),
        }]));
        let runtime = DockerContainerRuntime::new(fake);

        let result = runtime
            .run_detached(&sample_config())
            .expect("expected docker run to succeed");

        assert_eq!(result.stdout, "container-id\n");
    }

    #[test]
    fn docker_container_runtime_remove_invokes_rm_force() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "rm".into(),
                "-f".into(),
                "example".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["docker", "rm", "-f", "example"], "")),
        }]));
        let runtime = DockerContainerRuntime::new(fake);

        let result = runtime
            .remove("example")
            .expect("expected remove to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn docker_container_runtime_inspect_ip_handles_present_and_missing_ips() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: None,
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(success_result(
                    &["docker", "inspect", "-f", "{{...}}", "example"],
                    "10.0.0.5\n",
                )),
            },
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: None,
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(success_result(
                    &["docker", "inspect", "-f", "{{...}}", "example"],
                    "\n",
                )),
            },
        ]));
        let runtime = DockerContainerRuntime::new(fake);

        let ip = runtime
            .inspect_ip("example", "mesh-net")
            .expect("expected IP lookup to succeed");
        assert_eq!(ip, "10.0.0.5");

        let error = runtime
            .inspect_ip("example", "mesh-net")
            .expect_err("expected empty IP to fail");
        assert!(error.to_string().contains("no IP on network mesh-net"));
    }

    #[test]
    fn docker_container_runtime_is_running_reflects_inspect_output() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: Some(vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.State.Running}}".into(),
                    "example".into(),
                ]),
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(success_result(
                    &["docker", "inspect", "-f", "{{.State.Running}}", "example"],
                    "true\n",
                )),
            },
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: Some(vec![
                    "docker".into(),
                    "inspect".into(),
                    "-f".into(),
                    "{{.State.Running}}".into(),
                    "example".into(),
                ]),
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(CommandResult {
                    args: vec![
                        "docker".into(),
                        "inspect".into(),
                        "-f".into(),
                        "{{.State.Running}}".into(),
                        "example".into(),
                    ],
                    returncode: 1,
                    stdout: "false\n".to_string(),
                    stderr: String::new(),
                }),
            },
        ]));
        let runtime = DockerContainerRuntime::new(fake);

        assert!(
            runtime
                .is_running("example")
                .expect("expected inspect to succeed")
        );
        assert!(
            !runtime
                .is_running("example")
                .expect("expected inspect to succeed")
        );
    }

    #[test]
    fn docker_container_runtime_exec_command_builds_expected_args() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "exec".into(),
                "example".into(),
                "echo".into(),
                "hello".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &["docker", "exec", "example", "echo", "hello"],
                "hello\n",
            )),
        }]));
        let runtime = DockerContainerRuntime::new(fake);

        let result = runtime
            .exec_command("example", &["echo", "hello"])
            .expect("expected exec to succeed");

        assert_eq!(result.stdout, "hello\n");
    }

    #[test]
    fn docker_container_runtime_list_formatted_uses_ps_without_all_flag() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "ps".into(),
                "--filter".into(),
                "label=suite=mesh".into(),
                "--format".into(),
                "{{.Names}}".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &[
                    "docker",
                    "ps",
                    "--filter",
                    "label=suite=mesh",
                    "--format",
                    "{{.Names}}",
                ],
                "svc-1\n",
            )),
        }]));
        let runtime = DockerContainerRuntime::new(fake);

        let result = runtime
            .list_formatted(&["--filter", "label=suite=mesh"], "{{.Names}}")
            .expect("expected list_formatted to succeed");

        assert_eq!(result.stdout, "svc-1\n");
    }

    #[test]
    fn docker_container_runtime_write_file_invokes_docker_cp() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: None,
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&["docker", "cp"], "")),
        }]));
        let runtime = DockerContainerRuntime::new(fake.clone());

        runtime
            .write_file("example", "/tmp/config.yaml", "kind: ConfigMap")
            .expect("expected write_file to succeed");

        let invocation = last_invocation(fake.as_ref());
        assert_eq!(invocation.method, FakeProcessMethod::Run);
        assert_eq!(invocation.args[0], "docker");
        assert_eq!(invocation.args[1], "cp");
        assert_eq!(invocation.args[3], "example:/tmp/config.yaml");
        assert!(!invocation.args[2].is_empty());
    }

    #[test]
    fn docker_container_runtime_create_network_skips_create_when_network_exists() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "network".into(),
                "ls".into(),
                "--filter".into(),
                "name=^mesh-net$".into(),
                "--format".into(),
                "{{.Name}}".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(
                &[
                    "docker",
                    "network",
                    "ls",
                    "--filter",
                    "name=^mesh-net$",
                    "--format",
                    "{{.Name}}",
                ],
                "mesh-net\n",
            )),
        }]));
        let runtime = DockerContainerRuntime::new(fake.clone());

        runtime
            .create_network("mesh-net", "172.18.0.0/24")
            .expect("expected create_network to succeed");

        assert_eq!(fake.invocations().len(), 1);
    }

    #[test]
    fn docker_container_runtime_remove_by_label_removes_each_match() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: Some(vec![
                    "docker".into(),
                    "ps".into(),
                    "-a".into(),
                    "--filter".into(),
                    "label=suite=mesh".into(),
                    "--format".into(),
                    "{{.Names}}".into(),
                ]),
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(success_result(
                    &[
                        "docker",
                        "ps",
                        "-a",
                        "--filter",
                        "label=suite=mesh",
                        "--format",
                        "{{.Names}}",
                    ],
                    "cp-1\ndp-1\n",
                )),
            },
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: Some(vec![
                    "docker".into(),
                    "rm".into(),
                    "-f".into(),
                    "cp-1".into(),
                ]),
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(success_result(&["docker", "rm", "-f", "cp-1"], "")),
            },
            FakeResponse {
                expected_program: "docker".to_string(),
                expected_args: Some(vec![
                    "docker".into(),
                    "rm".into(),
                    "-f".into(),
                    "dp-1".into(),
                ]),
                expected_method: Some(FakeProcessMethod::Run),
                result: Ok(success_result(&["docker", "rm", "-f", "dp-1"], "")),
            },
        ]));
        let runtime = DockerContainerRuntime::new(fake);

        let removed = runtime
            .remove_by_label("suite=mesh")
            .expect("expected remove_by_label to succeed");

        assert_eq!(removed, vec!["cp-1", "dp-1"]);
    }

    #[test]
    fn fake_container_runtime_tracks_container_lifecycle() {
        let runtime = FakeContainerRuntime::new();
        let config = sample_config();

        runtime
            .create_network("mesh-net", "172.18.0.0/24")
            .expect("expected network creation to succeed");
        runtime
            .run_detached(&config)
            .expect("expected run_detached to succeed");
        assert!(
            runtime
                .is_running("example")
                .expect("expected running check to succeed")
        );
        assert_eq!(
            runtime
                .inspect_ip("example", "mesh-net")
                .expect("expected IP lookup to succeed"),
            "172.18.0.2"
        );
        runtime
            .write_file("example", "/tmp/config.yaml", "data")
            .expect("expected write_file to succeed");

        let removed = runtime
            .remove_by_label("suite=mesh")
            .expect("expected remove_by_label to succeed");
        assert_eq!(removed, vec!["example"]);
        assert!(
            !runtime
                .is_running("example")
                .expect("expected running check to succeed")
        );
    }

    #[test]
    fn docker_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<DockerContainerRuntime>();
        assert_send_sync::<FakeContainerRuntime>();
    }

    // -- Contract tests: fake satisfies the same invariants as production --

    mod contracts {
        use super::*;

        fn contract_run_detached_returns_id(runtime: &dyn ContainerRuntime) {
            let config = sample_config();
            let result = runtime
                .run_detached(&config)
                .expect("run_detached should succeed");
            assert_eq!(result.returncode, 0);
            assert!(
                !result.stdout.trim().is_empty(),
                "stdout should contain a container ID"
            );
            let _ = runtime.remove(&config.name);
        }

        fn contract_is_running_reflects_state(runtime: &dyn ContainerRuntime) {
            let config = sample_config();
            runtime
                .run_detached(&config)
                .expect("run_detached should succeed");
            let running = runtime
                .is_running(&config.name)
                .expect("is_running should succeed");
            assert!(running, "should be running after run_detached");
            runtime.remove(&config.name).expect("remove should succeed");
            let still = runtime
                .is_running(&config.name)
                .expect("is_running check after remove");
            assert!(!still, "should not be running after remove");
        }

        fn contract_remove_is_idempotent(runtime: &dyn ContainerRuntime) {
            let result = runtime.remove("nonexistent-contract-test");
            assert!(
                result.is_ok(),
                "removing nonexistent container should not fail"
            );
        }

        fn contract_network_lifecycle(runtime: &dyn ContainerRuntime) {
            let name = "contract-test-net";
            runtime
                .create_network(name, "172.250.0.0/24")
                .expect("create_network should succeed");
            runtime
                .remove_network(name)
                .expect("remove_network should succeed");
        }

        #[test]
        fn fake_satisfies_run_detached_returns_id() {
            contract_run_detached_returns_id(&FakeContainerRuntime::new());
        }

        #[test]
        fn fake_satisfies_is_running_reflects_state() {
            contract_is_running_reflects_state(&FakeContainerRuntime::new());
        }

        #[test]
        fn fake_satisfies_remove_is_idempotent() {
            contract_remove_is_idempotent(&FakeContainerRuntime::new());
        }

        #[test]
        fn fake_satisfies_network_lifecycle() {
            contract_network_lifecycle(&FakeContainerRuntime::new());
        }
    }
}
