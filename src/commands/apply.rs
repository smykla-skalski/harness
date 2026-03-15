use std::path::PathBuf;

use crate::cli::RunDirArgs;
use crate::context::RunContext;
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};
use crate::exec::kubectl;
use crate::io::append_markdown_row;
use crate::resolve::resolve_manifest_path;

fn resolve_kubeconfig(
    ctx: &RunContext,
    explicit: Option<&str>,
    cluster: Option<&str>,
) -> Result<PathBuf, CliError> {
    if let Some(kc) = explicit {
        return Ok(PathBuf::from(kc));
    }
    if let Some(cluster_name) = cluster
        && let Some(ref spec) = ctx.cluster
    {
        let configs = spec.kubeconfigs();
        if let Some(kc) = configs.get(cluster_name) {
            return Ok(PathBuf::from(kc));
        }
    }
    if let Some(ref spec) = ctx.cluster {
        return Ok(PathBuf::from(spec.primary_kubeconfig()));
    }
    Err(CliErrorKind::MissingRunContextValue {
        field: "kubeconfig".into(),
    }
    .into())
}

/// Apply manifests to the cluster.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    kubeconfig: Option<&str>,
    cluster: Option<&str>,
    manifests: &[String],
    step: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = super::resolve_run_dir(run_dir_args)?;
    let ctx = RunContext::from_run_dir(&run_dir)?;
    let kc = resolve_kubeconfig(&ctx, kubeconfig, cluster)?;
    let _kc_str = kc.to_string_lossy().to_string();

    for manifest_raw in manifests {
        let manifest = resolve_manifest_path(manifest_raw, Some(&run_dir))?;
        let manifest_str = manifest.to_string_lossy().to_string();
        kubectl(Some(&kc), &["apply", "-f", &manifest_str], &[0])?;

        let manifest_index = ctx.layout.manifests_dir().join("manifest-index.md");
        let rel = manifest.strip_prefix(ctx.layout.run_dir()).map_or_else(
            |_| manifest.display().to_string(),
            |p| p.display().to_string(),
        );
        let notes = step.map_or_else(String::new, |s| format!("{s}: "));
        append_markdown_row(
            &manifest_index,
            &["copied_at", "manifest", "validated", "applied", "notes"],
            &[&utc_now(), &rel, "PASS", "PASS", &notes],
        )?;
        println!("{}", manifest.display());
    }
    Ok(0)
}
