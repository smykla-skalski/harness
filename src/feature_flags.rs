//! Runtime hook feature flags.
//!
//! One unfinished hook family ships today but slows every tool call without
//! useful guidance. It is off by default and re-enabled per agent install
//! through env vars or CLI flags:
//!
//! - `HARNESS_FEATURE_SUITE_HOOKS=1` / `--enable-suite-hooks` re-enables the
//!   suite lifecycle hooks: `guard-stop`, `context-agent`, `validate-agent`,
//!   `tool-failure` (Claude/Gemini/Copilot enrich-failure).
//! - `HARNESS_FEATURE_ACP=0` disables ACP managed-agent start routes. ACP is
//!   enabled by default now that the blocking permission modal has landed.
//! - `HARNESS_FEATURE_REVIEWS_BACKGROUND_AUTO=1` enables background Reviews
//!   policy runs. It is off by default because it can approve or merge GitHub
//!   pull requests without a same-moment user confirmation.
//! - `HARNESS_FEATURE_TASK_BOARD_PROMPT_OVERRIDES=1` (2026-07-25, tracking issue
//!   #336) lets `HARNESS_TASK_BOARD_PROMPTS_FILE` replace the prompts agents run
//!   with. Off by default so shipped prompts stay byte-identical.
//! - `HARNESS_FEATURE_TASK_BOARD_AUTOMATION_V2=0` disables the durable Task Board
//!   automation engine and retains the legacy orchestrator compatibility path.
//!   Without an override, the durable path is enabled.
//! - `harness-daemon serve --disable-acp` / `--enable-acp` applies the same
//!   gate as a process-scoped override without mutating the caller shell env.
//!
//! Resolution order: explicit process-scoped daemon override (when supplied)
//! wins over env vars, and env vars override each feature's default baseline.
//! ACP and durable Task Board automation default on; suite hooks and background
//! Reviews automation default off. Truthy values match the existing harness
//! convention used by `HARNESS_OTEL_EXPORT`.
//!
//! Removal trigger: drop this whole module, the CLI arg on `BootstrapArgs`,
//! and the `flags` parameter threaded through
//! `src/setup/wrapper/registrations.rs` once the gated family is useful by
//! default. Project rule: a new hook lands with its handler doing observable
//! work, or behind a dated flag in this module with a tracking issue. See
//! AGENTS.md / CLAUDE.md for the convention statement.

use std::sync::{Mutex, MutexGuard};

use crate::task_board::TaskBoardTriageEscalationConfig;
use crate::workspace::normalized_env_value;

/// Env var that re-enables suite-lifecycle hooks in generated configs.
pub const SUITE_HOOKS_ENV: &str = "HARNESS_FEATURE_SUITE_HOOKS";
/// Env var that enables ACP managed-agent runtime routes before the modal ships.
pub const ACP_ENV: &str = "HARNESS_FEATURE_ACP";
/// Env var that enables background Reviews policy runs.
pub const REVIEWS_BACKGROUND_AUTO_ENV: &str = "HARNESS_FEATURE_REVIEWS_BACKGROUND_AUTO";
/// Env var that enables the durable Task Board automation engine.
pub const TASK_BOARD_AUTOMATION_V2_ENV: &str = "HARNESS_FEATURE_TASK_BOARD_AUTOMATION_V2";
/// Env var that enables triage escalation to an agent.
pub const TASK_BOARD_TRIAGE_ESCALATION_ENV: &str = "HARNESS_FEATURE_TASK_BOARD_TRIAGE_ESCALATION";
/// Env var bounding concurrent escalation executor runs.
pub const TASK_BOARD_TRIAGE_ESCALATION_MAX_CONCURRENT_ENV: &str =
    "HARNESS_TASK_BOARD_TRIAGE_ESCALATION_MAX_CONCURRENT";
/// Env var bounding the total enqueued-but-unresolved escalation queue depth.
pub const TASK_BOARD_TRIAGE_ESCALATION_MAX_PENDING_ENV: &str =
    "HARNESS_TASK_BOARD_TRIAGE_ESCALATION_MAX_PENDING";
/// Env var bounding how long a claimed escalation may run before timing out.
pub const TASK_BOARD_TRIAGE_ESCALATION_TIMEOUT_SECONDS_ENV: &str =
    "HARNESS_TASK_BOARD_TRIAGE_ESCALATION_TIMEOUT_SECONDS";
/// Env var that lets a prompt configuration file replace shipped prompts.
pub const TASK_BOARD_PROMPT_OVERRIDES_ENV: &str = "HARNESS_FEATURE_TASK_BOARD_PROMPT_OVERRIDES";
/// Env var naming the prompt configuration file to load when overrides are on.
pub const TASK_BOARD_PROMPTS_FILE_ENV: &str = "HARNESS_TASK_BOARD_PROMPTS_FILE";

static ACP_RUNTIME_OVERRIDE: Mutex<Option<bool>> = Mutex::new(None);

/// Whether ACP managed-agent routes are enabled.
#[must_use]
pub fn acp_enabled_from_env() -> bool {
    if let Some(value) = *acp_runtime_override_slot() {
        return value;
    }
    env_enabled_by_default(ACP_ENV)
}

/// Whether Reviews policy runs may start or resume from background triggers.
#[must_use]
pub fn reviews_background_auto_enabled_from_env() -> bool {
    env_truthy(REVIEWS_BACKGROUND_AUTO_ENV)
}

/// Whether the durable Task Board automation engine may admit work.
#[must_use]
pub fn task_board_automation_v2_enabled_from_env() -> bool {
    env_enabled_by_default(TASK_BOARD_AUTOMATION_V2_ENV)
}

/// Whether a prompt configuration file may replace the prompts agents run
/// with. Off by default: with the flag clear the shipped prompts render
/// exactly as they always have, so nothing customized means nothing changed.
#[must_use]
pub fn task_board_prompt_overrides_enabled_from_env() -> bool {
    env_truthy(TASK_BOARD_PROMPT_OVERRIDES_ENV)
}

/// The prompt configuration file to load, when one is configured.
#[must_use]
pub fn task_board_prompts_file_from_env() -> Option<String> {
    normalized_env_value(TASK_BOARD_PROMPTS_FILE_ENV)
}

/// Ceiling for `HARNESS_TASK_BOARD_TRIAGE_ESCALATION_TIMEOUT_SECONDS`, well
/// under `chrono::Duration::seconds`'s own panic bound (`i64::MAX / 1000`).
/// A raw unclamped override -- someone reaching for "disable the timeout" --
/// would otherwise panic the sweep on its first tick and wedge the whole
/// escalation loop task permanently (a daemon restart re-reads the same env
/// and dies again).
const TASK_BOARD_TRIAGE_ESCALATION_MAX_TIMEOUT_SECONDS: u64 = 3600;

/// Resolve the triage escalation feature's bounded config from env vars,
/// once at daemon startup. Off by default -- see
/// [`TaskBoardTriageEscalationConfig::disabled`] for why. A malformed
/// numeric override falls back to the compiled-in default rather than
/// failing daemon startup over a tuning knob; `max_concurrent`/`max_pending`
/// are floored at 1 (a 0 would silently disable the feature while
/// `enabled: true`) and `timeout_seconds` is capped, both regardless of
/// whether the override parsed or fell back to the default.
#[must_use]
pub fn task_board_triage_escalation_config_from_env() -> TaskBoardTriageEscalationConfig {
    let defaults = TaskBoardTriageEscalationConfig::disabled();
    TaskBoardTriageEscalationConfig {
        enabled: env_truthy(TASK_BOARD_TRIAGE_ESCALATION_ENV),
        max_concurrent: env_usize(
            TASK_BOARD_TRIAGE_ESCALATION_MAX_CONCURRENT_ENV,
            defaults.max_concurrent,
        )
        .max(1),
        max_pending: env_usize(
            TASK_BOARD_TRIAGE_ESCALATION_MAX_PENDING_ENV,
            defaults.max_pending,
        )
        .max(1),
        timeout_seconds: env_u64(
            TASK_BOARD_TRIAGE_ESCALATION_TIMEOUT_SECONDS_ENV,
            defaults.timeout_seconds,
        )
        .clamp(1, TASK_BOARD_TRIAGE_ESCALATION_MAX_TIMEOUT_SECONDS),
    }
}

fn env_usize(name: &str, default: usize) -> usize {
    normalized_env_value(name)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn env_u64(name: &str, default: u64) -> u64 {
    normalized_env_value(name)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

/// Apply a process-scoped ACP enablement override for the lifetime of the guard.
///
/// This is used by `harness-daemon serve` / `harness-daemon dev` so one daemon process
/// can explicitly opt in or out without mutating the caller's shell env. The
/// override wins over `HARNESS_FEATURE_ACP` while the guard is alive.
#[must_use]
pub(crate) fn scoped_acp_enabled_override(value: Option<bool>) -> AcpRuntimeOverrideGuard {
    let mut slot = acp_runtime_override_slot();
    let previous = *slot;
    *slot = value;
    drop(slot);
    AcpRuntimeOverrideGuard { previous }
}

fn acp_runtime_override_slot() -> MutexGuard<'static, Option<bool>> {
    match ACP_RUNTIME_OVERRIDE.lock() {
        Ok(slot) => slot,
        Err(poisoned) => poisoned.into_inner(),
    }
}

pub(crate) struct AcpRuntimeOverrideGuard {
    previous: Option<bool>,
}

impl Drop for AcpRuntimeOverrideGuard {
    fn drop(&mut self) {
        *acp_runtime_override_slot() = self.previous;
    }
}

/// Toggles for the optional hook families written into runtime configs.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RuntimeHookFlags {
    /// When `true`, generate `guard-stop`, `context-agent`, `validate-agent`,
    /// and the Claude/Gemini/Copilot `tool-failure` hook.
    pub suite_hooks: bool,
}

impl RuntimeHookFlags {
    /// The toggle forced on. Useful in tests that need parity with the
    /// pre-flag baseline.
    #[must_use]
    pub const fn all_enabled() -> Self {
        Self { suite_hooks: true }
    }

    /// The toggle forced off. Same as `Default`, exposed for readability at call sites.
    #[must_use]
    pub const fn all_disabled() -> Self {
        Self { suite_hooks: false }
    }

    /// Resolve flags from env vars only. Used by code paths that have no CLI
    /// surface (e.g. the doctor check that compares on-disk configs against
    /// the bootstrap contract).
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            suite_hooks: env_truthy(SUITE_HOOKS_ENV),
        }
    }

    /// Resolve flags using CLI overrides on top of env vars. `None` means the
    /// CLI did not supply the override; fall back to the env var.
    #[must_use]
    pub fn resolve(cli_suite_hooks: Option<bool>) -> Self {
        let env = Self::from_env();
        Self {
            suite_hooks: cli_suite_hooks.unwrap_or(env.suite_hooks),
        }
    }
}

fn env_truthy(name: &str) -> bool {
    normalized_env_value(name).is_some_and(|value| env_value_truthy(&value))
}

fn env_enabled_by_default(name: &str) -> bool {
    normalized_env_value(name).is_none_or(|value| env_value_truthy(&value))
}

fn env_value_truthy(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    static ACP_OVERRIDE_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn with_clean_env<R>(body: impl FnOnce() -> R) -> R {
        temp_env::with_vars(
            [
                (SUITE_HOOKS_ENV, None::<&str>),
                (ACP_ENV, None::<&str>),
                (REVIEWS_BACKGROUND_AUTO_ENV, None::<&str>),
                (TASK_BOARD_AUTOMATION_V2_ENV, None::<&str>),
            ],
            body,
        )
    }

    #[test]
    fn defaults_match_feature_rollout_baselines() {
        with_clean_env(|| {
            let flags = RuntimeHookFlags::from_env();
            assert!(!flags.suite_hooks);
            assert!(acp_enabled_from_env());
            assert!(!reviews_background_auto_enabled_from_env());
            assert!(task_board_automation_v2_enabled_from_env());
        });
    }

    #[test]
    fn truthy_env_values_enable_each_flag_independently() {
        for value in ["1", "true", "TRUE", "yes", "Yes", "on", "ON"] {
            temp_env::with_vars([(SUITE_HOOKS_ENV, Some(value))], || {
                let flags = RuntimeHookFlags::from_env();
                assert!(
                    flags.suite_hooks,
                    "value {value:?} should enable suite hooks"
                );
            });
        }
    }

    #[test]
    fn falsy_or_unset_env_keeps_flags_disabled() {
        for value in ["", "0", "false", "no", "off", "${NOT_EXPANDED}", "unset"] {
            temp_env::with_vars([(SUITE_HOOKS_ENV, Some(value))], || {
                let flags = RuntimeHookFlags::from_env();
                assert!(
                    !flags.suite_hooks,
                    "value {value:?} should not enable suite hooks"
                );
            });
        }
    }

    #[test]
    fn cli_override_wins_over_env() {
        temp_env::with_vars([(SUITE_HOOKS_ENV, Some("1"))], || {
            let flags = RuntimeHookFlags::resolve(Some(false));
            assert!(!flags.suite_hooks);

            let flags = RuntimeHookFlags::resolve(None);
            assert!(flags.suite_hooks);
        });
    }

    #[test]
    fn cli_override_can_enable_when_env_unset() {
        with_clean_env(|| {
            let flags = RuntimeHookFlags::resolve(Some(true));
            assert!(flags.suite_hooks);
        });
    }

    #[test]
    fn acp_flag_uses_same_truthy_env_convention() {
        temp_env::with_var(ACP_ENV, Some("1"), || {
            assert!(acp_enabled_from_env());
        });
        temp_env::with_var(ACP_ENV, Some("false"), || {
            assert!(!acp_enabled_from_env());
        });
    }

    #[test]
    fn reviews_background_auto_flag_uses_same_truthy_env_convention() {
        temp_env::with_var(REVIEWS_BACKGROUND_AUTO_ENV, Some("1"), || {
            assert!(reviews_background_auto_enabled_from_env());
        });
        temp_env::with_var(REVIEWS_BACKGROUND_AUTO_ENV, Some("false"), || {
            assert!(!reviews_background_auto_enabled_from_env());
        });
    }

    #[test]
    fn task_board_automation_v2_defaults_on_and_accepts_explicit_overrides() {
        for value in [None, Some(""), Some(" \t ")] {
            temp_env::with_var(TASK_BOARD_AUTOMATION_V2_ENV, value, || {
                assert!(task_board_automation_v2_enabled_from_env());
            });
        }
        for value in ["1", "true", "TRUE", "yes", "on"] {
            temp_env::with_var(TASK_BOARD_AUTOMATION_V2_ENV, Some(value), || {
                assert!(task_board_automation_v2_enabled_from_env());
            });
        }
        for value in ["0", "false", "FALSE", "no", "off"] {
            temp_env::with_var(TASK_BOARD_AUTOMATION_V2_ENV, Some(value), || {
                assert!(!task_board_automation_v2_enabled_from_env());
            });
        }
    }

    #[test]
    fn scoped_acp_override_wins_over_env_and_resets_after_drop() {
        let _guard = ACP_OVERRIDE_TEST_LOCK.lock().expect("override test lock");
        temp_env::with_var(ACP_ENV, Some("0"), || {
            assert!(!acp_enabled_from_env());

            let override_guard = scoped_acp_enabled_override(Some(true));
            assert!(acp_enabled_from_env());

            drop(override_guard);
            assert!(!acp_enabled_from_env());
        });
    }
}
