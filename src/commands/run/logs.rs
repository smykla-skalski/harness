use clap::Args;

use crate::blocks::ContainerRuntime;
use crate::commands::RunDirArgs;
use crate::commands::resolve_run_services;
use crate::errors::CliError;

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
    name: &str,
    tail: u32,
    follow: bool,
    run_dir_args: &RunDirArgs,
    docker: &dyn ContainerRuntime,
) -> Result<i32, CliError> {
    let services = resolve_run_services(run_dir_args)?;
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
    use crate::cluster::{ClusterSpec, Platform};
    use crate::runtime::ClusterRuntime;

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
