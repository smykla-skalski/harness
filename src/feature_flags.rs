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
//! - `harness daemon serve --disable-acp` / `--enable-acp` applies the same
//!   gate as a process-scoped override without mutating the caller shell env.
//!
//! Resolution order: explicit process-scoped daemon override (when supplied)
//! wins over env vars, env vars over the disabled-by-default baseline. Truthy
//! values match the existing harness convention used by `HARNESS_OTEL_EXPORT`.
//!
//! Removal trigger: drop this whole module, the two CLI args on `BootstrapArgs`
//! and `GenerateAgentAssetsArgs`, the `flags` parameter threaded through
//! `src/setup/wrapper/registrations.rs` and `src/agents/assets/planning.rs`,
//! and the `_legacy` test wrappers in `src/agents/assets/{mod.rs,planning.rs}`
//! once the gated family is useful by default. Project rule: a new hook lands
//! with its handler doing observable work, or behind a dated flag in this
//! module with a tracking issue. See AGENTS.md / CLAUDE.md for the convention
//! statement.

use std::sync::{Mutex, MutexGuard};

use crate::workspace::normalized_env_value;

/// Env var that re-enables suite-lifecycle hooks in generated configs.
pub const SUITE_HOOKS_ENV: &str = "HARNESS_FEATURE_SUITE_HOOKS";
/// Env var that enables ACP managed-agent runtime routes before the modal ships.
pub const ACP_ENV: &str = "HARNESS_FEATURE_ACP";

static ACP_RUNTIME_OVERRIDE: Mutex<Option<bool>> = Mutex::new(None);

/// Whether ACP managed-agent routes are enabled.
#[must_use]
pub fn acp_enabled_from_env() -> bool {
    if let Some(value) = *acp_runtime_override_slot() {
        return value;
    }
    normalized_env_value(ACP_ENV).is_none_or(|value| env_value_truthy(&value))
}

/// Apply a process-scoped ACP enablement override for the lifetime of the guard.
///
/// This is used by `harness daemon serve` / `daemon dev` so one daemon process
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
            [(SUITE_HOOKS_ENV, None::<&str>), (ACP_ENV, None::<&str>)],
            body,
        )
    }

    #[test]
    fn defaults_to_all_disabled() {
        with_clean_env(|| {
            let flags = RuntimeHookFlags::from_env();
            assert!(!flags.suite_hooks);
            assert!(acp_enabled_from_env());
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
