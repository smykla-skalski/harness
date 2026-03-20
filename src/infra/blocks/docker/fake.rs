use std::collections::{HashMap, HashSet};
use std::sync;

use super::{ContainerConfig, ContainerRuntime};
use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

#[derive(Debug)]
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
