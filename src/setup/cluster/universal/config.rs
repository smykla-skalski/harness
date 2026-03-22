use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::run_command;
use crate::kernel::topology::ClusterSpec;
use crate::run::application::RunApplication;

/// Docker filter patterns for finding kuma-cp images. The glob `*kuma-cp`
/// matches both bare `kuma-cp` and namespaced `kumahq/kuma-cp` repositories.
pub(crate) const KUMA_CP_IMAGE_FILTERS: &[&str] = &["reference=*kuma-cp", "reference=kuma-cp"];

/// Search for a local kuma-cp image using multiple reference filters.
///
/// Docker's `--filter reference=` doesn't glob across namespaces the same
/// way in all versions, so we try the namespaced glob first and fall back
/// to the bare name.
fn find_local_kuma_cp_image() -> Result<Option<String>, CliError> {
    for filter in KUMA_CP_IMAGE_FILTERS {
        let result = run_command(
            &[
                "docker",
                "images",
                "--format",
                "{{.Repository}}:{{.Tag}}",
                "--filter",
                filter,
            ],
            None,
            None,
            &[0],
        )?;
        let first_line = result.stdout.lines().next().unwrap_or("").trim();
        if !first_line.is_empty() && first_line != "<none>:<none>" {
            return Ok(Some(first_line.to_string()));
        }
    }
    Ok(None)
}

pub(crate) fn resolve_cp_image(
    root: &Path,
    explicit: Option<&str>,
    skip_build: bool,
) -> Result<String, CliError> {
    if let Some(img) = explicit {
        return Ok(img.to_string());
    }

    if let Some(found) = find_local_kuma_cp_image()? {
        return Ok(found);
    }

    if skip_build {
        return Err(CliErrorKind::image_build_failed(
            "kuma-cp image not found and --no-build was specified",
        )
        .into());
    }

    build_kuma_images(root)?;
    require_built_cp_image()
}

fn build_kuma_images(root: &Path) -> Result<(), CliError> {
    run_command(&["make", "images"], Some(root), None, &[0])
        .map_err(|e| CliErrorKind::image_build_failed("make images").with_details(e.message()))?;
    Ok(())
}

fn require_built_cp_image() -> Result<String, CliError> {
    find_local_kuma_cp_image()?.ok_or_else(|| {
        CliErrorKind::image_build_failed("kuma-cp image not found after build").into()
    })
}

/// Resolve the effective store type for a cluster operation.
///
/// For `up` operations, uses the CLI-supplied store directly.
/// For `down` operations, checks the persisted spec first and falls back to CLI.
pub(crate) fn resolve_effective_store(is_up: bool, cli_store: &str) -> String {
    if is_up {
        return cli_store.to_string();
    }
    match persisted_store_type() {
        Ok(Some(store)) => store,
        Ok(None) | Err(_) => cli_store.to_string(),
    }
}

fn persisted_store_type() -> Result<Option<String>, CliError> {
    Ok(load_persisted_cluster_spec()?.and_then(|spec| spec.store_type))
}

/// Load persisted cluster spec from the session context file.
///
/// # Errors
/// Returns `CliError` on corrupt JSON or parse failures. Returns `Ok(None)` when
/// the context file is missing.
pub(crate) fn load_persisted_cluster_spec() -> Result<Option<ClusterSpec>, CliError> {
    RunApplication::load_current_cluster_spec()
}

pub(super) fn resolve_universal_cp_image(
    is_up: bool,
    root: &Path,
    explicit: Option<&str>,
    skip_build: bool,
) -> Result<String, CliError> {
    if is_up {
        return resolve_cp_image(root, explicit, skip_build);
    }
    Ok(String::new())
}
