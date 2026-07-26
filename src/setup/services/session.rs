use std::env;
use std::path::Path;

use harness_kernel::errors::CliError;
use crate::setup::wrapper;
use crate::workspace::compact;

pub(crate) fn bootstrap_project_wrapper(project_dir: &Path) {
    let path_env = env::var("PATH").unwrap_or_default();
    let _ = wrapper::main(project_dir, &path_env);
}

pub(crate) fn restore_compact_handoff(project_dir: &Path) -> Result<Option<String>, CliError> {
    let handoff = compact::pending_compact_handoff(project_dir)?;
    let Some(handoff) = handoff else {
        return Ok(None);
    };

    let diverged = compact::verify_fingerprints(&handoff);
    let context = compact::render_hydration_context(&handoff, &diverged);
    let _ = compact::consume_compact_handoff(project_dir, handoff);
    Ok(Some(context))
}
