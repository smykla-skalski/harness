//! Resolving the prompt catalog the daemon runs with, once at startup.
//!
//! Every failure here keeps the shipped prompts: a daemon that cannot read its
//! prompt configuration still has to start and still has to run agents. The
//! failure is logged at `warn`/`error` rather than swallowed, and a
//! customization that parsed but names a variable that does not exist is not a
//! failure here at all -- it is carried in the catalog and refuses the spawn of
//! the one agent it belongs to.

use tracing::{error, info, warn};

use harness_kernel::errors::CliError;
use harness_workspace::workspace::normalized_env_value;

use super::prompt_catalog::PromptCatalog;

/// Env var that lets a prompt configuration file replace shipped prompts.
/// Mirrors `HARNESS_FEATURE_TASK_BOARD_PROMPT_OVERRIDES` in
/// `harness_feature_flags::feature_flags`, which lists every operator-facing
/// flag; this is the one flag whose implementation lives with its sole
/// consumer instead.
pub const TASK_BOARD_PROMPT_OVERRIDES_ENV: &str = "HARNESS_FEATURE_TASK_BOARD_PROMPT_OVERRIDES";
/// Env var naming the prompt configuration file to load when overrides are on.
pub const TASK_BOARD_PROMPTS_FILE_ENV: &str = "HARNESS_TASK_BOARD_PROMPTS_FILE";

/// Ceiling for the prompt configuration file. Every shipped prompt together is
/// a few kilobytes, so this leaves room for prompts far longer than any model
/// usefully accepts while keeping the pre-listener read bounded.
pub(crate) const MAX_PROMPT_CONFIGURATION_BYTES: usize = 512 * 1024;

/// Whether a prompt configuration file may replace the prompts agents run
/// with. Off by default: with the flag clear the shipped prompts render
/// exactly as they always have, so nothing customized means nothing changed.
#[must_use]
pub fn task_board_prompt_overrides_enabled_from_env() -> bool {
    normalized_env_value(TASK_BOARD_PROMPT_OVERRIDES_ENV)
        .is_some_and(|value| env_value_truthy(&value))
}

/// The prompt configuration file to load, when one is configured.
#[must_use]
pub fn task_board_prompts_file_from_env() -> Option<String> {
    normalized_env_value(TASK_BOARD_PROMPTS_FILE_ENV)
}

fn env_value_truthy(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

/// Read the configuration without trusting the path. This runs before the
/// daemon binds its listener, so an unbounded read is a way to stop the daemon
/// starting at all: a FIFO with no writer blocks forever and a character
/// device like `/dev/zero` never ends. The file is opened once and everything
/// is checked through that handle, so the path cannot be swapped for something
/// worse between a check and the read; `O_NONBLOCK` keeps even the open from
/// parking on a writerless FIFO, and changes nothing for a regular file.
fn read_bounded(path: &str) -> Result<Vec<u8>, String> {
    use std::io::Read;

    use fs_err::os::unix::fs::OpenOptionsExt;

    let file = fs_err::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| error.to_string())?;
    let metadata = file.metadata().map_err(|error| error.to_string())?;
    if !metadata.is_file() {
        return Err("not a regular file".to_string());
    }
    let length = metadata.len();
    if length > MAX_PROMPT_CONFIGURATION_BYTES as u64 {
        return Err(format!(
            "{length} bytes exceeds the {MAX_PROMPT_CONFIGURATION_BYTES} byte limit"
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_PROMPT_CONFIGURATION_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > MAX_PROMPT_CONFIGURATION_BYTES {
        return Err(format!(
            "grew past the {MAX_PROMPT_CONFIGURATION_BYTES} byte limit during the read"
        ));
    }
    Ok(bytes)
}

/// Resolve the prompt catalog from the feature flag and the configured file.
#[must_use]
pub fn resolve_prompt_catalog_from_env() -> PromptCatalog {
    if !task_board_prompt_overrides_enabled_from_env() {
        return PromptCatalog::builtin();
    }
    let Some(path) = task_board_prompts_file_from_env() else {
        log_prompt_overrides_without_file();
        return PromptCatalog::builtin();
    };
    let Some(bytes) = load_configured_prompt_bytes(&path) else {
        return PromptCatalog::builtin();
    };
    parse_configured_prompt_catalog(&path, &bytes)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macros expand into chains clippy reads as branchy"
)]
fn log_prompt_overrides_without_file() {
    info!(
        target: "harness::task_board",
        "prompt overrides enabled without a configured file; using builtin prompts",
    );
}

/// Read the configured prompt file, `None` when it cannot be read. A daemon
/// that cannot read its prompt configuration still has to start, so this
/// falls back rather than failing.
fn load_configured_prompt_bytes(path: &str) -> Option<Vec<u8>> {
    match read_bounded(path) {
        Ok(bytes) => Some(bytes),
        Err(error) => {
            log_prompt_configuration_unreadable(path, &error);
            None
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macros expand into chains clippy reads as branchy"
)]
fn log_prompt_configuration_unreadable(path: &str, error: &str) {
    warn!(
        target: "harness::task_board",
        %path, %error,
        "cannot read the prompt configuration; using builtin prompts",
    );
}

/// Parse the configured bytes, falling back to the builtin catalog rather
/// than failing the daemon on a configuration that does not parse.
fn parse_configured_prompt_catalog(path: &str, bytes: &[u8]) -> PromptCatalog {
    match PromptCatalog::from_json(bytes) {
        Ok(catalog) => {
            report_loaded_catalog(path, &catalog);
            catalog
        }
        Err(error) => {
            log_invalid_prompt_configuration(path, &error);
            PromptCatalog::builtin()
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macros expand into chains clippy reads as branchy"
)]
fn log_invalid_prompt_configuration(path: &str, error: &CliError) {
    error!(
        target: "harness::task_board",
        %path, %error,
        "prompt configuration is invalid; using builtin prompts",
    );
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
