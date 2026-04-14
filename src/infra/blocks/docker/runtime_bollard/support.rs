use std::collections::HashMap;
use std::path::Path;
use std::thread;
use std::time::Instant;

use bollard::body_full;
use bollard::exec::StartExecResults;
use bollard::models::{ContainerCreateBody, ContainerCreateResponse, HostConfig, PortBinding};
use bollard::query_parameters::{
    CreateContainerOptionsBuilder, CreateImageOptionsBuilder, InspectContainerOptions,
    UploadToContainerOptionsBuilder,
};
use bytes::Bytes;
use futures_util::TryStreamExt;
use tar::{Builder, Header};

use super::BollardContainerRuntime;
use crate::infra::blocks::BlockError;
use crate::infra::blocks::docker::ContainerConfig;
use crate::infra::exec::CommandResult;
use crate::infra::exec::RUNTIME;

impl BollardContainerRuntime {
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

    pub(super) fn exec_output_to_result(
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

    pub(super) fn container_create_body(
        config: &ContainerConfig,
    ) -> Result<ContainerCreateBody, BlockError> {
        let labels = config.labels.iter().cloned().collect::<HashMap<_, _>>();
        let env = config
            .env
            .iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect::<Vec<_>>();
        let exposed_ports = config
            .ports
            .iter()
            .map(|port| Self::container_port_key(port.container_port))
            .collect::<Vec<_>>();
        let port_bindings = config
            .ports
            .iter()
            .map(|port| {
                (
                    Self::container_port_key(port.container_port),
                    Some(vec![PortBinding {
                        host_ip: Some("0.0.0.0".to_string()),
                        host_port: Some(
                            port.host_port
                                .map_or_else(String::new, |host_port| host_port.to_string()),
                        ),
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

    pub(super) fn create_container_request(
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

    pub(super) fn pull_image(&self, image: &str) -> Result<(), BlockError> {
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

    pub(super) fn wait_removed(&self, name: &str) -> Result<(), BlockError> {
        let deadline = Instant::now() + Self::REMOVE_TIMEOUT;
        loop {
            match Self::block_on(
                &format!("inspect_container {name}"),
                self.docker
                    .inspect_container(name, None::<InspectContainerOptions>),
            ) {
                Ok(_) => {}
                Err(error) if Self::is_not_found(&error) => return Ok(()),
                Err(error) => return Err(error),
            }
            if Instant::now() >= deadline {
                return Err(BlockError::message(
                    "docker",
                    &format!("remove_container {name}"),
                    format!(
                        "timed out waiting for container `{name}` to be removed after {}s",
                        Self::REMOVE_TIMEOUT.as_secs()
                    ),
                ));
            }
            thread::sleep(Self::REMOVE_POLL_INTERVAL);
        }
    }

    pub(super) fn write_file_contents(
        &self,
        container: &str,
        path: &str,
        content: &str,
    ) -> Result<(), BlockError> {
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
}
