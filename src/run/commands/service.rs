use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::run::application::{RunApplication, StartServiceRequest};
use crate::run::args::RunDirArgs;

use super::shared::resolve_run_application;

impl Execute for ServiceArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        service(self)
    }
}

/// Arguments for `harness run kuma service`.
#[derive(Debug, Clone, Args)]
pub struct ServiceArgs {
    /// Service action.
    #[arg(value_parser = ["up", "down", "list"])]
    pub action: String,
    /// Service name.
    pub name: Option<String>,
    /// Service image.
    #[arg(long)]
    pub image: Option<String>,
    /// Service port.
    #[arg(long)]
    pub port: Option<u16>,
    /// Mesh name.
    #[arg(long, default_value = "default")]
    pub mesh: String,
    /// Enable transparent proxy.
    #[arg(long)]
    pub transparent_proxy: bool,
    /// Readiness timeout in seconds.
    #[arg(long, default_value = "60")]
    pub timeout: u64,
    /// Custom dataplane template path.
    #[arg(long)]
    pub dataplane_template: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Manage universal mode test service containers.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn service(args: &ServiceArgs) -> Result<i32, CliError> {
    match args.action.as_str() {
        "up" => service_up(args),
        "down" => service_down(args.name.as_deref()),
        "list" => service_list(&args.run_dir),
        _ => Err(
            CliErrorKind::usage_error(format!("unknown service action: {}", args.action)).into(),
        ),
    }
}

fn service_up(args: &ServiceArgs) -> Result<i32, CliError> {
    let name = args
        .name
        .as_deref()
        .ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    let port = args
        .port
        .ok_or_else(|| CliErrorKind::usage_error("service port is required"))?;
    let run = resolve_run_application(&args.run_dir)?;
    run.start_service(&StartServiceRequest {
        name,
        image: args.image.as_deref(),
        port,
        mesh: &args.mesh,
        transparent_proxy: args.transparent_proxy,
        timeout: args.timeout,
    })?;
    println!("{name}");
    Ok(0)
}

fn service_down(name: Option<&str>) -> Result<i32, CliError> {
    let name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    RunApplication::remove_managed_service_container(name)?;
    println!("{name} removed");
    Ok(0)
}

fn service_list(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    if let Ok(run) = resolve_run_application(run_dir_args) {
        for row in run.list_service_containers()? {
            println!("{}\t{}", row.name, row.status);
        }
        return Ok(0);
    }

    for row in RunApplication::list_managed_service_containers()? {
        println!("{}\t{}", row.name, row.status);
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use crate::platform::cluster::{ClusterSpec, Platform};
    use crate::platform::runtime::ClusterRuntime;
    use crate::run::services::service_lifecycle::extract_pem_certificates;

    #[test]
    fn resolve_image_explicit_wins() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let runtime = ClusterRuntime::from_spec(&spec);
        let result = runtime.service_image(Some("my-image:v1")).unwrap();
        assert_eq!(result, "my-image:v1");
    }

    #[test]
    fn resolve_image_derives_from_cp_image() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.cp_image = Some("kuma-cp:dev".into());
        let runtime = ClusterRuntime::from_spec(&spec);
        let result = runtime.service_image(None).unwrap();
        assert_eq!(result, "kuma-universal:dev");
    }

    #[test]
    fn extract_pem_certificates_finds_certs() {
        let raw = "CONNECTED\n\
            depth=0 CN=kuma-cp\n\
            ---\n\
            -----BEGIN CERTIFICATE-----\n\
            MIIB1234==\n\
            -----END CERTIFICATE-----\n\
            ---\n\
            other noise\n";
        let cert = extract_pem_certificates(raw);
        assert!(cert.contains("BEGIN CERTIFICATE"));
        assert!(cert.contains("MIIB1234=="));
        assert!(!cert.contains("CONNECTED"));
    }

    #[test]
    fn extract_pem_certificates_empty_on_no_cert() {
        let raw = "CONNECTED\nno cert here\n";
        assert!(extract_pem_certificates(raw).is_empty());
    }

    #[test]
    fn resolve_image_errors_when_no_cp_image() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let runtime = ClusterRuntime::from_spec(&spec);
        let result = runtime.service_image(None);
        assert!(result.is_err());
    }
}
