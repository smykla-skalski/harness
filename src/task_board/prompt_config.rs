//! Resolving the prompt catalog the daemon runs with, once at startup.
//!
//! Every failure here keeps the shipped prompts: a daemon that cannot read its
//! prompt configuration still has to start and still has to run agents. The
//! failure is logged at `warn`/`error` rather than swallowed, and a
//! customization that parsed but names a variable that does not exist is not a
//! failure here at all -- it is carried in the catalog and refuses the spawn of
//! the one agent it belongs to.

use tracing::{error, info, warn};

use crate::feature_flags::{
    task_board_prompt_overrides_enabled_from_env, task_board_prompts_file_from_env,
};

use super::prompt_catalog::PromptCatalog;

/// Resolve the prompt catalog from the feature flag and the configured file.
#[must_use]
pub(crate) fn resolve_prompt_catalog_from_env() -> PromptCatalog {
    if !task_board_prompt_overrides_enabled_from_env() {
        return PromptCatalog::builtin();
    }
    let Some(path) = task_board_prompts_file_from_env() else {
        info!(
            target: "harness::task_board",
            "prompt overrides enabled without a configured file; using builtin prompts",
        );
        return PromptCatalog::builtin();
    };
    let bytes = match fs_err::read(&path) {
        Ok(bytes) => bytes,
        Err(error) => {
            warn!(
                target: "harness::task_board",
                %path, %error,
                "cannot read the prompt configuration; using builtin prompts",
            );
            return PromptCatalog::builtin();
        }
    };
    match PromptCatalog::from_json(&bytes) {
        Ok(catalog) => {
            report_loaded_catalog(&path, &catalog);
            catalog
        }
        Err(error) => {
            error!(
                target: "harness::task_board",
                %path, %error,
                "prompt configuration is invalid; using builtin prompts",
            );
            PromptCatalog::builtin()
        }
    }
}

/// A file that parsed but customized nothing is worth saying out loud: it
/// looks like a working configuration and behaves like no configuration at
/// all. Anything it did customize is named, because a daemon not running the
/// shipped prompts is the first thing to know when its agents behave oddly.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macros expand into chains clippy reads as branchy"
)]
fn report_loaded_catalog(path: &str, catalog: &PromptCatalog) {
    if catalog.is_builtin() {
        warn!(
            target: "harness::task_board",
            %path,
            "prompt configuration customizes no prompt; using builtin prompts",
        );
        return;
    }
    info!(
        target: "harness::task_board",
        %path,
        customized = ?catalog.customized_prompts(),
        "loaded prompt configuration",
    );
}

#[cfg(test)]
#[path = "prompt_config_tests.rs"]
mod tests;
