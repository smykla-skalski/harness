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

/// Ceiling for the prompt configuration file. Every shipped prompt together is
/// a few kilobytes, so this leaves room for prompts far longer than any model
/// usefully accepts while keeping the pre-listener read bounded.
pub(crate) const MAX_PROMPT_CONFIGURATION_BYTES: usize = 512 * 1024;

/// Read the configuration without trusting the path. This runs before the
/// daemon binds its listener, so an unbounded read is a way to stop the daemon
/// starting at all: a FIFO with no writer blocks forever and a character
/// device like `/dev/zero` never ends. Only an ordinary file within the cap is
/// read, and the length is checked from its metadata before any bytes are
/// pulled in.
fn read_bounded(path: &str) -> Result<Vec<u8>, String> {
    let metadata = fs_err::metadata(path).map_err(|error| error.to_string())?;
    if !metadata.is_file() {
        return Err("not a regular file".to_string());
    }
    let length = metadata.len();
    if length > MAX_PROMPT_CONFIGURATION_BYTES as u64 {
        return Err(format!(
            "{length} bytes exceeds the {MAX_PROMPT_CONFIGURATION_BYTES} byte limit"
        ));
    }
    fs_err::read(path).map_err(|error| error.to_string())
}

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
    let bytes = match read_bounded(&path) {
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
    for (prompt, error) in catalog.unusable_prompts() {
        warn!(
            target: "harness::task_board",
            %path, %prompt, %error,
            "configured prompt is unusable and will refuse every agent it starts",
        );
    }
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
