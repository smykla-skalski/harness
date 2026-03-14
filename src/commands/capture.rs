use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::context::RunContext;
use crate::core_defs::utc_now;
use crate::errors::CliError;
use crate::exec::kubectl;
use crate::io::write_text;
use crate::resolve::resolve_run_directory;

fn resolve_run_dir(args: &RunDirArgs) -> Result<PathBuf, CliError> {
    let lookup = crate::context::RunLookup {
        run_dir: args.run_dir.clone(),
        run_id: args.run_id.clone(),
        run_root: args.run_root.clone(),
    };
    Ok(resolve_run_directory(&lookup)?.run_dir)
}

/// Capture cluster pod state for a run.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    kubeconfig: Option<&str>,
    label: &str,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;

    let kc = kubeconfig.map(PathBuf::from).or_else(|| {
        ctx.cluster
            .as_ref()
            .map(|c| PathBuf::from(c.primary_kubeconfig()))
    });

    let timestamp = utc_now().replace(':', "");
    let capture_path = ctx
        .layout
        .state_dir()
        .join(format!("{label}-{timestamp}.json"));

    let result = kubectl(
        kc.as_deref(),
        &["get", "pods", "--all-namespaces", "-o", "json"],
        &[0],
    )?;

    write_text(&capture_path, &result.stdout)?;

    let rel = capture_path
        .strip_prefix(ctx.layout.run_dir())
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| capture_path.display().to_string());

    println!("{rel}");
    Ok(0)
}
