use std::collections::HashMap;
use std::future::Future;
use std::io::{Write as _, stderr, stdout};
use std::iter::once;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use bollard::Docker;
use bollard::body_full;
use bollard::container::LogOutput;
use bollard::errors::Error as BollardError;
use bollard::exec::{CreateExecOptions, StartExecOptions, StartExecResults};
use bollard::models::{
    ContainerCreateBody, ContainerCreateResponse, ContainerSummary, HealthStatusEnum, HostConfig,
    Ipam, IpamConfig, NetworkCreateRequest, PortBinding, RestartPolicy, RestartPolicyNameEnum,
};
use bollard::query_parameters::{
    CreateContainerOptionsBuilder, CreateImageOptionsBuilder, InspectContainerOptions,
    ListContainersOptionsBuilder, ListNetworksOptionsBuilder, LogsOptionsBuilder,
    RemoveContainerOptions, StartContainerOptions, UploadToContainerOptionsBuilder,
};
use bytes::Bytes;
use futures_util::{StreamExt, TryStreamExt};
use tar::{Builder, Header};

use super::{ContainerConfig, ContainerRuntime};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::BlockError;
use crate::infra::exec::{CommandResult, RUNTIME};

/// Production container runtime backed by the Docker Engine API via Bollard.
pub struct BollardContainerRuntime {
    docker: Docker,
}

impl BollardContainerRuntime {
    /// Create a runtime connected to the local Docker Engine API.
    ///
    /// # Errors
    ///
    /// Returns `CliError` when the local Docker Engine connection cannot be initialized.
    pub fn new() -> Result<Self, CliError> {
        let docker = Docker::connect_with_local_defaults().map_err(|error| {
            CliErrorKind::command_failed("docker engine connect").with_details(error.to_string())
        })?;
        Ok(Self { docker })
    }

    pub fn daemon_reachable() -> bool {
        let Ok(docker) = Docker::connect_with_local_defaults() else {
            return false;
        };
        RUNTIME.block_on(docker.ping()).is_ok()
    }

    fn block_on<T>(
        operation: &str,
        future: impl Future<Output = Result<T, BollardError>>,
    ) -> Result<T, BlockError> {
        RUNTIME
            .block_on(future)
            .map_err(|error| BlockError::new("docker", operation, error))
    }

    fn is_not_found(error: &BlockError) -> bool {
        error
            .cause
            .downcast_ref::<BollardError>()
            .is_some_and(|error| {
                matches!(
                    error,
                    BollardError::DockerResponseServerError {
                        status_code: 404,
                        ..
                    }
                )
            })
    }

    fn is_missing_local_image(error: &BlockError) -> bool {
        error
            .cause
            .downcast_ref::<BollardError>()
            .is_some_and(|error| {
                matches!(
                    error,
                    BollardError::DockerResponseServerError {
                        status_code: 404,
                        message,
                    } if message.to_ascii_lowercase().contains("no such image")
                )
            })
    }

    fn collect_output(
        output: impl futures_util::Stream<Item = Result<LogOutput, BollardError>>,
    ) -> Result<(String, String), BlockError> {
        RUNTIME.block_on(async move {
            let mut stdout = String::new();
            let mut stderr = String::new();
            futures_util::pin_mut!(output);
            while let Some(chunk) = output.next().await {
                match chunk.map_err(|error| BlockError::new("docker", "stream output", error))? {
                    LogOutput::StdOut { message }
                    | LogOutput::Console { message }
                    | LogOutput::StdIn { message } => {
                        stdout.push_str(&String::from_utf8_lossy(&message));
                    }
                    LogOutput::StdErr { message } => {
                        stderr.push_str(&String::from_utf8_lossy(&message));
                    }
                }
            }
            Ok::<_, BlockError>((stdout, stderr))
        })
    }

    fn command_result(
        args: &[String],
        stdout: String,
        stderr: String,
        returncode: i32,
    ) -> CommandResult {
        CommandResult {
            args: args.to_vec(),
            returncode,
            stdout,
            stderr,
        }
    }

    fn parse_filters(filter_args: &[&str]) -> HashMap<String, Vec<String>> {
        let mut filters = HashMap::new();
        let mut iter = filter_args.iter();
        while let Some(flag) = iter.next() {
            if *flag != "--filter" {
                continue;
            }
            if let Some(raw) = iter.next()
                && let Some((kind, value)) = raw.split_once('=')
            {
                filters
                    .entry(kind.to_string())
                    .or_insert_with(Vec::new)
                    .push(value.to_string());
            }
        }
        filters
    }

    fn summary_name(summary: &ContainerSummary) -> Option<String> {
        summary
            .names
            .as_ref()
            .and_then(|names| names.first())
            .map(|name| name.trim_start_matches('/').to_string())
    }

    fn summary_networks(summary: &ContainerSummary) -> Option<String> {
        summary
            .network_settings
            .as_ref()
            .and_then(|settings| settings.networks.as_ref())
            .map(|networks| networks.keys().cloned().collect::<Vec<_>>().join(","))
    }

    fn format_summary(summary: &ContainerSummary, format_template: &str) -> Option<String> {
        let name = Self::summary_name(summary)?;
        let status = summary.status.clone().unwrap_or_default();
        let id = summary.id.clone().unwrap_or_default();
        let image = summary.image.clone().unwrap_or_default();
        let networks = Self::summary_networks(summary).unwrap_or_default();
        match format_template {
            "{{.Names}}\t{{.Status}}" => Some(format!("{name}\t{status}")),
            "{{.ID}}" => Some(id),
            "{{.Image}}" => Some(image),
            "{{.Status}}" => Some(status),
            "{{.Networks}}" => Some(networks),
            "{{json .}}" => Some(
                serde_json::json!({
                    "ID": id,
                    "Image": image,
                    "Names": name,
                    "Status": status,
                    "Networks": networks,
                })
                .to_string(),
            ),
            _ => Some(name),
        }
    }

    fn create_tarball(path: &str, content: &str) -> Result<Bytes, BlockError> {
        let file_path = Path::new(path);
        let file_name = file_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| BlockError::message("docker", "write_file", "invalid container path"))?;
        let mut archive = Vec::new();
        {
            let mut builder = Builder::new(&mut archive);
            let mut header = Header::new_gnu();
            header.set_size(content.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder
                .append_data(&mut header, file_name, content.as_bytes())
                .map_err(|error| BlockError::new("docker", "write_file tar", error))?;
            builder
                .finish()
                .map_err(|error| BlockError::new("docker", "write_file tar", error))?;
        }
        Ok(Bytes::from(archive))
    }

    fn restart_policy(name: &str) -> Result<RestartPolicy, BlockError> {
        let policy_name = match name {
            "no" => RestartPolicyNameEnum::NO,
            "always" => RestartPolicyNameEnum::ALWAYS,
            "unless-stopped" => RestartPolicyNameEnum::UNLESS_STOPPED,
            "on-failure" => RestartPolicyNameEnum::ON_FAILURE,
            "" => RestartPolicyNameEnum::EMPTY,
            other => {
                return Err(BlockError::message(
                    "docker",
                    "run_detached",
                    format!("unsupported restart policy `{other}`"),
                ));
            }
        };
        Ok(RestartPolicy {
            name: Some(policy_name),
            maximum_retry_count: None,
        })
    }

    fn exit_code(code: i64) -> i32 {
        match i32::try_from(code) {
            Ok(code) => code,
            Err(_) if code.is_negative() => i32::MIN,
            Err(_) => i32::MAX,
        }
    }

    fn exec_failure_details(returncode: i32, stdout: &str, stderr: &str) -> String {
        let stderr = stderr.trim();
        if !stderr.is_empty() {
            return stderr.to_string();
        }
        let stdout = stdout.trim();
        if !stdout.is_empty() {
            return stdout.to_string();
        }
        format!("exit code {returncode}")
    }

    fn exec_output_to_result(
        &self,
        operation: &str,
        args: &[String],
        exec_id: &str,
        output: StartExecResults,
    ) -> Result<CommandResult, BlockError> {
        match output {
            StartExecResults::Attached { output, .. } => {
                let (stdout, stderr) = Self::collect_output(output)?;
                let inspect = Self::block_on(
                    &format!("inspect_exec {exec_id}"),
                    self.docker.inspect_exec(exec_id),
                )?;
                let returncode = inspect.exit_code.map_or(0, Self::exit_code);
                if returncode != 0 {
                    return Err(BlockError::message(
                        "docker",
                        operation,
                        Self::exec_failure_details(returncode, &stdout, &stderr),
                    ));
                }
                Ok(Self::command_result(args, stdout, stderr, returncode))
            }
            StartExecResults::Detached => {
                Ok(Self::command_result(args, String::new(), String::new(), 0))
            }
        }
    }

    fn extract_tail(args: &[&str]) -> String {
        let mut iter = args.iter();
        while let Some(flag) = iter.next() {
            if *flag == "--tail"
                && let Some(value) = iter.next()
            {
                return (*value).to_string();
            }
        }
        "all".to_string()
    }

    fn container_create_body(config: &ContainerConfig) -> Result<ContainerCreateBody, BlockError> {
        let labels = config.labels.iter().cloned().collect::<HashMap<_, _>>();
        let env = config
            .env
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>();
        let exposed_ports = config
            .ports
            .iter()
            .map(|(_, container)| format!("{container}/tcp"))
            .collect::<Vec<_>>();
        let port_bindings = config
            .ports
            .iter()
            .map(|(host, container)| {
                (
                    format!("{container}/tcp"),
                    Some(vec![PortBinding {
                        host_ip: Some("0.0.0.0".to_string()),
                        host_port: Some(host.to_string()),
                    }]),
                )
            })
            .collect::<HashMap<_, _>>();
        let restart_policy = config
            .restart_policy
            .as_deref()
            .map(Self::restart_policy)
            .transpose()?;

        Ok(ContainerCreateBody {
            image: Some(config.image.clone()),
            env: (!env.is_empty()).then_some(env),
            cmd: (!config.command.is_empty()).then_some(config.command.clone()),
            entrypoint: config.entrypoint.clone(),
            labels: (!labels.is_empty()).then_some(labels),
            exposed_ports: (!exposed_ports.is_empty()).then_some(exposed_ports),
            host_config: Some(HostConfig {
                network_mode: Some(config.network.clone()),
                port_bindings: (!port_bindings.is_empty()).then_some(port_bindings),
                restart_policy,
                ..Default::default()
            }),
            ..Default::default()
        })
    }

    fn create_container_request(
        &self,
        config: &ContainerConfig,
    ) -> Result<ContainerCreateResponse, BlockError> {
        let container_config = Self::container_create_body(config)?;
        Self::block_on(
            &format!("create_container {}", config.name),
            self.docker.create_container(
                Some(
                    CreateContainerOptionsBuilder::default()
                        .name(&config.name)
                        .build(),
                ),
                container_config,
            ),
        )
    }

    fn pull_image(&self, image: &str) -> Result<(), BlockError> {
        let operation = format!("pull_image {image}");
        RUNTIME
            .block_on(async {
                self.docker
                    .create_image(
                        Some(
                            CreateImageOptionsBuilder::default()
                                .from_image(image)
                                .build(),
                        ),
                        None,
                        None,
                    )
                    .try_collect::<Vec<_>>()
                    .await
            })
            .map(|_| ())
            .map_err(|error| BlockError::new("docker", &operation, error))
    }
}

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
        if let Err(error) = result
            && !Self::is_not_found(&error)
        {
            return Err(error);
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
        let parent = Path::new(path)
            .parent()
            .and_then(|parent| parent.to_str())
            .unwrap_or("/");
        let archive = Self::create_tarball(path, content)?;
        Self::block_on(
            &format!("upload_to_container {container}"),
            self.docker.upload_to_container(
                container,
                Some(
                    UploadToContainerOptionsBuilder::default()
                        .path(parent)
                        .build(),
                ),
                body_full(archive),
            ),
        )?;
        Ok(())
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
        let deadline = Instant::now() + timeout;
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
            if Instant::now() >= deadline {
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

#[cfg(test)]
mod tests {
    use bollard::errors::Error as BollardError;

    use super::BollardContainerRuntime;
    use crate::infra::blocks::BlockError;

    #[test]
    fn missing_local_image_detection_matches_engine_error() {
        let error = BlockError::new(
            "docker",
            "create_container example",
            BollardError::DockerResponseServerError {
                status_code: 404,
                message: "No such image: missing:latest".to_string(),
            },
        );

        assert!(BollardContainerRuntime::is_missing_local_image(&error));
    }

    #[test]
    fn missing_local_image_detection_ignores_other_404s() {
        let error = BlockError::new(
            "docker",
            "create_container example",
            BollardError::DockerResponseServerError {
                status_code: 404,
                message: "network mesh-net not found".to_string(),
            },
        );

        assert!(!BollardContainerRuntime::is_missing_local_image(&error));
    }
}
