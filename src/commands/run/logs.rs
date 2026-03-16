use crate::cli::RunDirArgs;
use crate::cluster::ClusterSpec;
use crate::commands::resolve_run_context;
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

/// Resolve a container name from the cluster spec.
///
/// For compose deployments, maps member name to `{project}-{member}-1`.
/// Falls back to using the name directly (service containers).
fn resolve_container_name(name: &str, spec: &ClusterSpec) -> String {
    // Check if this name matches a cluster member
    for member in &spec.members {
        if member.name == name {
            // Compose-managed containers use {project}-{member}-1 naming
            if spec.docker_network.is_some() {
                let project = format!(
                    "harness-{}",
                    spec.members.first().map_or("default", |m| m.name.as_str())
                );
                if spec.is_compose_managed() {
                    return format!("{project}-{name}-1");
                }
            }
            // Direct docker container - use name as-is
            return name.to_string();
        }
    }
    // Not a member - assume it's a service container name
    name.to_string()
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
) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;
    let spec = ctx
        .cluster
        .as_ref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;

    let container = resolve_container_name(name, spec);
    let tail_str = tail.to_string();
    let mut args: Vec<&str> = vec!["logs", "--tail", &tail_str];
    if follow {
        args.push("-f");
    }
    args.push(&container);

    if follow {
        // Stream directly to terminal so the user sees output in real time.
        let mut docker_args: Vec<&str> = vec!["docker"];
        docker_args.extend_from_slice(&args);
        exec::run_command_inherited(&docker_args, &[0])?;
        Ok(0)
    } else {
        let result = exec::docker(&args, &[0])?;
        print!("{}", result.stdout);
        if !result.stderr.is_empty() {
            eprint!("{}", result.stderr);
        }
        Ok(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::{ClusterSpec, Platform};

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
        assert_eq!(resolve_container_name("test-cp", &spec), "test-cp");
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
        assert_eq!(resolve_container_name("g", &spec), "harness-g-g-1");
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
        assert_eq!(resolve_container_name("demo-svc", &spec), "demo-svc");
    }
}
