use std::collections::HashMap;
use std::io::{Write as _, stderr, stdout};
use std::iter::once;
use std::thread;
use std::time::Duration;

use bollard::container::LogOutput;
use bollard::exec::{CreateExecOptions, StartExecOptions};
use bollard::models::{HealthStatusEnum, Ipam, IpamConfig, NetworkCreateRequest};
use bollard::query_parameters::{
    InspectContainerOptions, ListContainersOptionsBuilder, ListNetworksOptionsBuilder,
    LogsOptionsBuilder, RemoveContainerOptions, StartContainerOptions,
};
use futures_util::StreamExt;

use super::BollardContainerRuntime;
use crate::infra::blocks::BlockError;
use crate::infra::blocks::docker::{ContainerConfig, ContainerRuntime};
use crate::infra::exec::{CommandResult, RUNTIME};

impl ContainerRuntime for BollardContainerRuntime {
    fn run_detached(&self, config: &ContainerConfig) -> Result<CommandResult, BlockError> {
        let create = match self.create_container_request(config) {
            Ok(create) => create,
            Err(error) if Self::is_missing_local_image(&error) => {
                self.pull_image(&config.image)?;
                self.create_container_request(config)?
            }
            Err(error) => return Err(error),
        };
        Self::block_on(
            &format!("start_container {}", config.name),
            self.docker
                .start_container(&config.name, None::<StartContainerOptions>),
        )?;
        Ok(Self::command_result(
            &[
                "docker".to_string(),
                "run".to_string(),
                "-d".to_string(),
                "--name".to_string(),
                config.name.clone(),
            ],
            format!("{}\n", create.id),
            String::new(),
            0,
        ))
    }

    fn remove(&self, name: &str) -> Result<CommandResult, BlockError> {
        let result = Self::block_on(
            &format!("remove_container {name}"),
            self.docker.remove_container(
                name,
                Some(RemoveContainerOptions {
                    force: true,
                    ..Default::default()
                }),
            ),
        );
        match result {
            Ok(()) => self.wait_removed(name)?,
            Err(error) if Self::is_not_found(&error) => {}
            Err(error) if Self::is_removal_in_progress(&error) => self.wait_removed(name)?,
            Err(error) => return Err(error),
        }
        Ok(Self::command_result(
            &[
                "docker".to_string(),
                "rm".to_string(),
                "-f".to_string(),
                name.to_string(),
            ],
            String::new(),
            String::new(),
            0,
        ))
    }

    fn remove_by_label(&self, label: &str) -> Result<Vec<String>, BlockError> {
        let mut filters = HashMap::new();
        filters.insert("label".to_string(), vec![label.to_string()]);
        let summaries = Self::block_on(
            &format!("list_containers label={label}"),
            self.docker.list_containers(Some(
                ListContainersOptionsBuilder::default()
                    .all(true)
                    .filters(&filters)
                    .build(),
            )),
        )?;
        let mut names = Vec::new();
        for summary in summaries {
            if let Some(name) = Self::summary_name(&summary) {
                self.remove(&name)?;
                names.push(name);
            }
        }
        Ok(names)
    }

    fn is_running(&self, name: &str) -> Result<bool, BlockError> {
        match Self::block_on(
            &format!("inspect_container {name}"),
            self.docker
                .inspect_container(name, None::<InspectContainerOptions>),
        ) {
            Ok(container) => Ok(container
                .state
                .as_ref()
                .and_then(|state| state.running)
                .unwrap_or(false)),
            Err(error) if Self::is_not_found(&error) => Ok(false),
            Err(error) => Err(error),
        }
    }

    fn inspect_ip(&self, container: &str, network: &str) -> Result<String, BlockError> {
        let details = Self::block_on(
            &format!("inspect_container {container}"),
            self.docker
                .inspect_container(container, None::<InspectContainerOptions>),
        )?;
        let ip = details
            .network_settings
            .as_ref()
            .and_then(|settings| settings.networks.as_ref())
            .and_then(|networks| networks.get(network))
            .and_then(|endpoint| endpoint.ip_address.as_ref())
            .map_or("", String::as_str)
            .trim()
            .to_string();
        if ip.is_empty() {
            return Err(BlockError::message(
                "docker",
                &format!("inspect_ip {container}"),
                format!("no IP on network {network}"),
            ));
        }
        Ok(ip)
    }

    fn inspect_primary_ip(&self, container: &str) -> Result<String, BlockError> {
        let details = Self::block_on(
            &format!("inspect_container {container}"),
            self.docker
                .inspect_container(container, None::<InspectContainerOptions>),
        )?;
        let ip = details
            .network_settings
            .as_ref()
            .and_then(|settings| settings.networks.as_ref())
            .and_then(|networks| {
                networks
                    .values()
                    .filter_map(|endpoint| endpoint.ip_address.as_ref())
                    .find(|ip| !ip.trim().is_empty())
                    .cloned()
            })
            .unwrap_or_default();
        if ip.is_empty() {
            return Err(BlockError::message(
                "docker",
                &format!("inspect_primary_ip {container}"),
                "container has no network IP",
            ));
        }
        Ok(ip)
    }

    fn inspect_host_port(&self, container: &str, container_port: u16) -> Result<u16, BlockError> {
        let details = Self::block_on(
            &format!("inspect_container {container}"),
            self.docker
                .inspect_container(container, None::<InspectContainerOptions>),
        )?;
        let key = Self::container_port_key(container_port);
        let host_port = details
            .network_settings
            .as_ref()
            .and_then(|settings| settings.ports.as_ref())
            .and_then(|ports| ports.get(&key))
            .and_then(Option::as_ref)
            .and_then(|bindings| bindings.first())
            .and_then(|binding| binding.host_port.as_deref())
            .ok_or_else(|| {
                BlockError::message(
                    "docker",
                    &format!("inspect_host_port {container}"),
                    format!("container port {container_port} is not published"),
                )
            })?;
        host_port.parse::<u16>().map_err(|error| {
            BlockError::message(
                "docker",
                &format!("inspect_host_port {container}"),
                format!("invalid published port `{host_port}`: {error}"),
            )
        })
    }

    fn list_formatted(
        &self,
        filter_args: &[&str],
        format_template: &str,
    ) -> Result<CommandResult, BlockError> {
        let filters = Self::parse_filters(filter_args);
        let summaries = Self::block_on(
            "list_containers formatted",
            self.docker.list_containers(Some(
                ListContainersOptionsBuilder::default()
                    .filters(&filters)
                    .build(),
            )),
        )?;
        let stdout = summaries
            .iter()
            .filter_map(|summary| Self::format_summary(summary, format_template))
            .collect::<Vec<_>>()
            .join("\n");
        let mut args = vec!["docker".to_string(), "ps".to_string()];
        args.extend(filter_args.iter().map(|arg| (*arg).to_string()));
        args.push("--format".to_string());
        args.push(format_template.to_string());
        Ok(Self::command_result(&args, stdout, String::new(), 0))
    }

    fn exec_command(&self, container: &str, command: &[&str]) -> Result<CommandResult, BlockError> {
        let create = Self::block_on(
            &format!("create_exec {container}"),
            self.docker.create_exec(
                container,
                CreateExecOptions {
                    attach_stdout: Some(true),
                    attach_stderr: Some(true),
                    cmd: Some(command.iter().map(|part| (*part).to_string()).collect()),
                    ..Default::default()
                },
            ),
        )?;
        let args = once("docker".to_string())
            .chain(once("exec".to_string()))
            .chain(once(container.to_string()))
            .chain(command.iter().map(|part| (*part).to_string()))
            .collect::<Vec<_>>();
        let output = Self::block_on(
            &format!("start_exec {container}"),
            self.docker.start_exec(
                &create.id,
                Some(StartExecOptions {
                    detach: false,
                    tty: false,
                    output_capacity: None,
                }),
            ),
        )?;
        self.exec_output_to_result(&format!("exec {container}"), &args, &create.id, output)
    }

    fn exec_detached(
        &self,
        container: &str,
        command: &[&str],
    ) -> Result<CommandResult, BlockError> {
        let create = Self::block_on(
            &format!("create_exec {container}"),
            self.docker.create_exec(
                container,
                CreateExecOptions {
                    cmd: Some(command.iter().map(|part| (*part).to_string()).collect()),
                    ..Default::default()
                },
            ),
        )?;
        let args = once("docker".to_string())
            .chain(once("exec".to_string()))
            .chain(once("-d".to_string()))
            .chain(once(container.to_string()))
            .chain(command.iter().map(|part| (*part).to_string()))
            .collect::<Vec<_>>();
        let output = Self::block_on(
            &format!("start_exec detached {container}"),
            self.docker.start_exec(
                &create.id,
                Some(StartExecOptions {
                    detach: true,
                    tty: false,
                    output_capacity: None,
                }),
            ),
        )?;
        self.exec_output_to_result(
            &format!("exec_detached {container}"),
            &args,
            &create.id,
            output,
        )
    }

    fn write_file(&self, container: &str, path: &str, content: &str) -> Result<(), BlockError> {
        self.write_file_contents(container, path, content)
    }

    fn create_network_labeled(
        &self,
        name: &str,
        subnet: &str,
        labels: &[(String, String)],
    ) -> Result<(), BlockError> {
        if self.network_exists(name)? {
            return Ok(());
        }
        let network_labels = labels.iter().cloned().collect::<HashMap<_, _>>();
        Self::block_on(
            &format!("create_network {name}"),
            self.docker.create_network(NetworkCreateRequest {
                name: name.to_string(),
                driver: Some("bridge".to_string()),
                internal: Some(false),
                attachable: Some(false),
                ingress: Some(false),
                enable_ipv4: Some(true),
                enable_ipv6: Some(false),
                options: Some(HashMap::new()),
                labels: (!network_labels.is_empty()).then_some(network_labels),
                ipam: Some(Ipam {
                    driver: None,
                    config: Some(vec![IpamConfig {
                        subnet: Some(subnet.to_string()),
                        ..Default::default()
                    }]),
                    options: None,
                }),
                ..Default::default()
            }),
        )?;
        Ok(())
    }

    fn network_exists(&self, name: &str) -> Result<bool, BlockError> {
        let mut filters = HashMap::new();
        filters.insert("name".to_string(), vec![name.to_string()]);
        let networks = Self::block_on(
            &format!("list_networks {name}"),
            self.docker.list_networks(Some(
                ListNetworksOptionsBuilder::default()
                    .filters(&filters)
                    .build(),
            )),
        )?;
        Ok(networks
            .iter()
            .any(|network| network.name.as_deref() == Some(name)))
    }

    fn remove_network(&self, name: &str) -> Result<(), BlockError> {
        let result = Self::block_on(
            &format!("remove_network {name}"),
            self.docker.remove_network(name),
        );
        if let Err(error) = result
            && !Self::is_not_found(&error)
        {
            return Err(error);
        }
        Ok(())
    }

    fn remove_networks_by_label(&self, label: &str) -> Result<Vec<String>, BlockError> {
        let mut filters = HashMap::new();
        filters.insert("label".to_string(), vec![label.to_string()]);
        let networks = Self::block_on(
            &format!("list_networks label={label}"),
            self.docker.list_networks(Some(
                ListNetworksOptionsBuilder::default()
                    .filters(&filters)
                    .build(),
            )),
        )?;
        let mut names = Vec::new();
        for network in networks {
            if let Some(name) = network.name {
                self.remove_network(&name)?;
                names.push(name);
            }
        }
        Ok(names)
    }

    fn wait_healthy(&self, container: &str, timeout: Duration) -> Result<(), BlockError> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let details = Self::block_on(
                &format!("inspect_container {container}"),
                self.docker
                    .inspect_container(container, None::<InspectContainerOptions>),
            )?;
            let state = details.state.as_ref();
            let running = state.and_then(|state| state.running).unwrap_or(false);
            let health = state
                .and_then(|state| state.health.as_ref())
                .and_then(|health| health.status.as_ref())
                .map(HealthStatusEnum::as_ref);
            match health {
                Some("healthy") => return Ok(()),
                Some("unhealthy") => {
                    return Err(BlockError::message(
                        "docker",
                        &format!("wait_healthy {container}"),
                        "container reported unhealthy",
                    ));
                }
                None if running => return Ok(()),
                Some(_) | None => {}
            }
            if std::time::Instant::now() >= deadline {
                return Err(BlockError::message(
                    "docker",
                    &format!("wait_healthy {container}"),
                    format!("timed out after {}s", timeout.as_secs()),
                ));
            }
            thread::sleep(Duration::from_millis(200));
        }
    }

    fn logs(&self, container: &str, args: &[&str]) -> Result<CommandResult, BlockError> {
        let tail = Self::extract_tail(args);
        let output = self.docker.logs(
            container,
            Some(
                LogsOptionsBuilder::default()
                    .follow(false)
                    .stdout(true)
                    .stderr(true)
                    .tail(&tail)
                    .build(),
            ),
        );
        let (stdout, stderr) = Self::collect_output(output)?;
        let mut command_args = vec!["docker".to_string(), "logs".to_string()];
        command_args.extend(args.iter().map(|arg| (*arg).to_string()));
        command_args.push(container.to_string());
        Ok(Self::command_result(&command_args, stdout, stderr, 0))
    }

    fn logs_follow(&self, container: &str, args: &[&str]) -> Result<i32, BlockError> {
        let tail = Self::extract_tail(args);
        let mut output = self.docker.logs(
            container,
            Some(
                LogsOptionsBuilder::default()
                    .follow(true)
                    .stdout(true)
                    .stderr(true)
                    .tail(&tail)
                    .build(),
            ),
        );
        RUNTIME.block_on(async move {
            while let Some(chunk) = output.next().await {
                match chunk.map_err(|error| BlockError::new("docker", "logs_follow", error))? {
                    LogOutput::StdOut { message }
                    | LogOutput::Console { message }
                    | LogOutput::StdIn { message } => {
                        stdout()
                            .write_all(&message)
                            .map_err(|error| BlockError::new("docker", "logs_follow", error))?;
                    }
                    LogOutput::StdErr { message } => {
                        stderr()
                            .write_all(&message)
                            .map_err(|error| BlockError::new("docker", "logs_follow", error))?;
                    }
                }
            }
            Ok::<_, BlockError>(0)
        })
    }
}
