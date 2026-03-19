use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_services_with_blocks;

impl Execute for LogsArgs {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        logs(context, &self.name, self.tail, self.follow, &self.run_dir)
    }
}

/// Arguments for `harness logs`.
#[derive(Debug, Clone, Args)]
pub struct LogsArgs {
    /// Container or member name.
    pub name: String,
    /// Number of log lines to show.
    #[arg(long, default_value = "100")]
    pub tail: u32,
    /// Follow log output.
    #[arg(long)]
    pub follow: bool,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Show container logs.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn logs(
    ctx: &AppContext,
    name: &str,
    tail: u32,
    follow: bool,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let services = resolve_run_services_with_blocks(run_dir_args, ctx.shared_blocks())?;
    let docker = services
        .blocks()
        .docker
        .as_deref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("docker"))?;
    let container = services.resolve_container_name(name);
    let tail_str = tail.to_string();
    let mut args: Vec<&str> = vec!["--tail", &tail_str];
    if follow {
        args.push("-f");
    }

    if follow {
        // Stream directly to terminal so the user sees output in real time.
        docker.logs_follow(container.as_ref(), &args)?;
    } else {
        let result = docker.logs(container.as_ref(), &args)?;
        print!("{}", result.stdout);
        if !result.stderr.is_empty() {
            eprint!("{}", result.stderr);
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use crate::platform::cluster::{ClusterSpec, Platform};
    use crate::platform::runtime::ClusterRuntime;

    #[test]
    fn resolve_direct_container_single_zone() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["test-cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        // Single-zone memory: direct docker, not compose
        let runtime = ClusterRuntime::from_spec(&spec);
        assert_eq!(runtime.resolve_container_name("test-cp"), "test-cp");
    }

    #[test]
    fn resolve_compose_container_multi_zone() {
        let spec = ClusterSpec::from_mode_with_platform(
            "global-zone-up",
            &["g".into(), "z".into(), "zone-1".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let runtime = ClusterRuntime::from_spec(&spec);
        assert_eq!(runtime.resolve_container_name("g"), "harness-g-g-1");
    }

    #[test]
    fn resolve_service_container_passthrough() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        // Name not matching any member => passthrough
        let runtime = ClusterRuntime::from_spec(&spec);
        assert_eq!(runtime.resolve_container_name("demo-svc"), "demo-svc");
    }
}
