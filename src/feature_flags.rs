//! Runtime hook feature flags.
//!
//! Two unfinished hook families ship today but slow every tool call without
//! useful guidance. They are off by default and re-enabled per agent install
//! through env vars or CLI flags:
//!
//! - `HARNESS_FEATURE_SUITE_HOOKS=1` / `--enable-suite-hooks` re-enables the
//!   suite lifecycle hooks: `guard-stop`, `context-agent`, `validate-agent`,
//!   `tool-failure` (Claude/Gemini/Copilot enrich-failure).
//! - `HARNESS_FEATURE_REPO_POLICY=1` / `--enable-repo-policy` re-enables the
//!   `repo-policy` pre-tool hook that warns about raw `cargo`/`xcodebuild`
//!   usage in repos that prefer `mise` tasks.
//!
//! Resolution order: explicit CLI override (when supplied) wins over env vars,
//! env vars over the disabled-by-default baseline. Truthy values match the
//! existing harness convention used by `HARNESS_OTEL_EXPORT`.
//!
//! Removal trigger: drop this whole module, the two CLI args on `BootstrapArgs`
//! and `GenerateAgentAssetsArgs`, the `flags` parameter threaded through
//! `src/setup/wrapper/registrations.rs` and `src/agents/assets/planning.rs`,
//! and the `_legacy` test wrappers in `src/agents/assets/{mod.rs,planning.rs}`
//! once both gated families are useful by default. Project rule: a new hook
//! lands with its handler doing observable work, or behind a dated flag in
//! this module with a tracking issue. See AGENTS.md / CLAUDE.md for the
//! convention statement.

use crate::workspace::normalized_env_value;

/// Env var that re-enables suite-lifecycle hooks in generated configs.
pub const SUITE_HOOKS_ENV: &str = "HARNESS_FEATURE_SUITE_HOOKS";
/// Env var that re-enables the `repo-policy` pre-tool hook in generated configs.
pub const REPO_POLICY_ENV: &str = "HARNESS_FEATURE_REPO_POLICY";

/// Toggles for the optional hook families written into runtime configs.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RuntimeHookFlags {
    /// When `true`, generate `guard-stop`, `context-agent`, `validate-agent`,
    /// and the Claude/Gemini/Copilot `tool-failure` hook.
    pub suite_hooks: bool,
    /// When `true`, generate the `repo-policy` pre-tool hook.
    pub repo_policy: bool,
}

impl RuntimeHookFlags {
    /// Both toggles forced on. Useful in tests that need parity with the
    /// pre-flag baseline.
    #[must_use]
    pub const fn all_enabled() -> Self {
        Self {
            suite_hooks: true,
            repo_policy: true,
        }
    }

    /// Both toggles off. Same as `Default`, exposed for readability at call sites.
    #[must_use]
    pub const fn all_disabled() -> Self {
        Self {
            suite_hooks: false,
            repo_policy: false,
        }
    }

    /// Resolve flags from env vars only. Used by code paths that have no CLI
    /// surface (e.g. the doctor check that compares on-disk configs against
    /// the bootstrap contract).
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            suite_hooks: env_truthy(SUITE_HOOKS_ENV),
            repo_policy: env_truthy(REPO_POLICY_ENV),
        }
    }

    /// Resolve flags using CLI overrides on top of env vars. `None` means the
    /// CLI did not supply the override; fall back to the env var.
    #[must_use]
    pub fn resolve(cli_suite_hooks: Option<bool>, cli_repo_policy: Option<bool>) -> Self {
        let env = Self::from_env();
        Self {
            suite_hooks: cli_suite_hooks.unwrap_or(env.suite_hooks),
            repo_policy: cli_repo_policy.unwrap_or(env.repo_policy),
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
        temp_env::with_vars(
            [
                (SUITE_HOOKS_ENV, None::<&str>),
                (REPO_POLICY_ENV, None::<&str>),
            ],
            body,
        )
    }

    #[test]
    fn defaults_to_all_disabled() {
        with_clean_env(|| {
            let flags = RuntimeHookFlags::from_env();
            assert!(!flags.suite_hooks);
            assert!(!flags.repo_policy);
        });
    }

    #[test]
    fn truthy_env_values_enable_each_flag_independently() {
        for value in ["1", "true", "TRUE", "yes", "Yes", "on", "ON"] {
            temp_env::with_vars(
                [
                    (SUITE_HOOKS_ENV, Some(value)),
                    (REPO_POLICY_ENV, None::<&str>),
                ],
                || {
                    let flags = RuntimeHookFlags::from_env();
                    assert!(
                        flags.suite_hooks,
                        "value {value:?} should enable suite hooks"
                    );
                    assert!(!flags.repo_policy);
                },
            );
        }
    }

    #[test]
    fn falsy_or_unset_env_keeps_flags_disabled() {
        for value in ["", "0", "false", "no", "off", "${NOT_EXPANDED}", "unset"] {
            temp_env::with_vars(
                [
                    (SUITE_HOOKS_ENV, Some(value)),
                    (REPO_POLICY_ENV, Some(value)),
                ],
                || {
                    let flags = RuntimeHookFlags::from_env();
                    assert!(
                        !flags.suite_hooks,
                        "value {value:?} should not enable suite hooks"
                    );
                    assert!(
                        !flags.repo_policy,
                        "value {value:?} should not enable repo-policy"
                    );
                },
            );
        }
    }

    #[test]
    fn cli_override_wins_over_env() {
        temp_env::with_vars(
            [(SUITE_HOOKS_ENV, Some("1")), (REPO_POLICY_ENV, Some("1"))],
            || {
                let flags = RuntimeHookFlags::resolve(Some(false), Some(false));
                assert!(!flags.suite_hooks);
                assert!(!flags.repo_policy);

                let flags = RuntimeHookFlags::resolve(None, None);
                assert!(flags.suite_hooks);
                assert!(flags.repo_policy);
            },
        );
    }

    #[test]
    fn cli_override_can_enable_when_env_unset() {
        with_clean_env(|| {
            let flags = RuntimeHookFlags::resolve(Some(true), None);
            assert!(flags.suite_hooks);
            assert!(!flags.repo_policy);
        });
    }
}
