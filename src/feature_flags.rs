//! Runtime hook feature flags.
//!
//! One unfinished hook family ships today but slows every tool call without
//! useful guidance. It is off by default and re-enabled per agent install
//! through env vars or CLI flags:
//!
//! - `HARNESS_FEATURE_SUITE_HOOKS=1` / `--enable-suite-hooks` re-enables the
//!   suite lifecycle hooks: `guard-stop`, `context-agent`, `validate-agent`,
//!   `tool-failure` (Claude/Gemini/Copilot enrich-failure).
//!
//! Resolution order: explicit CLI override (when supplied) wins over env vars,
//! env vars over the disabled-by-default baseline. Truthy values match the
//! existing harness convention used by `HARNESS_OTEL_EXPORT`.
//!
//! Removal trigger: drop this whole module, the two CLI args on `BootstrapArgs`
//! and `GenerateAgentAssetsArgs`, the `flags` parameter threaded through
//! `src/setup/wrapper/registrations.rs` and `src/agents/assets/planning.rs`,
//! and the `_legacy` test wrappers in `src/agents/assets/{mod.rs,planning.rs}`
//! once the gated family is useful by default. Project rule: a new hook lands
//! with its handler doing observable work, or behind a dated flag in this
//! module with a tracking issue. See AGENTS.md / CLAUDE.md for the convention
//! statement.

use crate::workspace::normalized_env_value;

/// Env var that re-enables suite-lifecycle hooks in generated configs.
pub const SUITE_HOOKS_ENV: &str = "HARNESS_FEATURE_SUITE_HOOKS";

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
    matches!(
        normalized_env_value(name)
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_clean_env<R>(body: impl FnOnce() -> R) -> R {
        temp_env::with_vars([(SUITE_HOOKS_ENV, None::<&str>)], body)
    }

    #[test]
    fn defaults_to_all_disabled() {
        with_clean_env(|| {
            let flags = RuntimeHookFlags::from_env();
            assert!(!flags.suite_hooks);
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
}
