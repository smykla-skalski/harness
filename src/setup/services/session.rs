use std::env;
use std::path::Path;

use tracing::warn;

use crate::errors::CliError;
use crate::platform::ephemeral_metallb;
use crate::run::application::RunApplication;
use crate::setup::wrapper;
use crate::workspace::compact;

pub(crate) fn bootstrap_project_wrapper(project_dir: &Path) {
    let path_env = env::var("PATH").unwrap_or_default();
    if let Err(error) = wrapper::main(project_dir, &path_env) {
        warn!(%error, "bootstrap failed");
    }
}

pub(crate) fn restore_compact_handoff(project_dir: &Path) -> Result<Option<String>, CliError> {
    let handoff = compact::pending_compact_handoff(project_dir)?;
    let Some(handoff) = handoff else {
        return Ok(None);
    };

    let diverged = compact::verify_fingerprints(&handoff);
    let context = compact::render_hydration_context(&handoff, &diverged);
    if let Err(error) = compact::consume_compact_handoff(project_dir, handoff) {
        warn!(%error, "compact handoff consume failed");
    }
    Ok(Some(context))
}

pub(crate) fn cleanup_current_run_context() -> Result<(), CliError> {
    let Some(run_dir) = RunApplication::current_run_dir()? else {
        return Ok(());
    };

    if run_dir.is_dir()
        && let Err(error) = ephemeral_metallb::cleanup_templates(&run_dir)
    {
        warn!(%error, "cleanup templates failed");
    }

    if let Err(error) = RunApplication::clear_current_pointer() {
        warn!(%error, "failed to remove run pointer");
    }
    Ok(())
}
