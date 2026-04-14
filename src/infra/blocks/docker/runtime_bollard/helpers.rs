use std::collections::HashMap;
use std::future::Future;

use bollard::container::LogOutput;
use bollard::errors::Error as BollardError;
use bollard::models::{ContainerSummary, RestartPolicy, RestartPolicyNameEnum};
use futures_util::StreamExt;

use super::BollardContainerRuntime;
use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;
use crate::infra::exec::RUNTIME;

impl BollardContainerRuntime {
    pub(super) fn block_on<T>(
        operation: &str,
        future: impl Future<Output = Result<T, BollardError>>,
    ) -> Result<T, BlockError> {
        RUNTIME
            .block_on(future)
            .map_err(|error| BlockError::new("docker", operation, error))
    }

    pub(super) fn is_not_found(error: &BlockError) -> bool {
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

    pub(super) fn is_missing_local_image(error: &BlockError) -> bool {
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

    pub(super) fn is_removal_in_progress(error: &BlockError) -> bool {
        error
            .cause
            .downcast_ref::<BollardError>()
            .is_some_and(|error| {
                matches!(
                    error,
                    BollardError::DockerResponseServerError {
                        status_code: 409,
                        message,
                    } if message.to_ascii_lowercase().contains("already in progress")
                )
            })
    }

    pub(super) fn collect_output(
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

    pub(super) fn command_result(
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

    pub(super) fn parse_filters(filter_args: &[&str]) -> HashMap<String, Vec<String>> {
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

    pub(super) fn summary_name(summary: &ContainerSummary) -> Option<String> {
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

    pub(super) fn format_summary(
        summary: &ContainerSummary,
        format_template: &str,
    ) -> Option<String> {
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

    pub(super) fn restart_policy(name: &str) -> Result<RestartPolicy, BlockError> {
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

    pub(super) fn exit_code(code: i64) -> i32 {
        match i32::try_from(code) {
            Ok(code) => code,
            Err(_) if code.is_negative() => i32::MIN,
            Err(_) => i32::MAX,
        }
    }

    pub(super) fn exec_failure_details(returncode: i32, stdout: &str, stderr: &str) -> String {
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

    pub(super) fn container_port_key(container_port: u16) -> String {
        format!("{container_port}/tcp")
    }

    pub(super) fn extract_tail(args: &[&str]) -> String {
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
}
