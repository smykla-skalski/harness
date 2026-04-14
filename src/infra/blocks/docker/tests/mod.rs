use std::sync::Arc;

use super::*;
use crate::infra::blocks::{
    FakeContainerRuntime, FakeInvocation, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
};
use temp_env::with_var;

mod backend_selection;
mod contracts;
mod inspect_and_network;
mod run_and_remove;

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
        ports: vec![ContainerPort::fixed(8080, 80)],
        labels: vec![("suite".to_string(), "mesh".to_string())],
        entrypoint: None,
        restart_policy: Some("unless-stopped".to_string()),
        extra_args: vec![],
        command: vec!["server".to_string()],
    }
}

fn last_invocation(fake: &FakeProcessExecutor) -> FakeInvocation {
    fake.invocations()
        .into_iter()
        .last()
        .expect("expected at least one invocation")
}
