use crate::workspace::normalized_env_value;

pub const SUITE_HOOKS_ENV: &str = "HARNESS_FEATURE_SUITE_HOOKS";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RuntimeHookFlags {
    pub suite_hooks: bool,
}

impl RuntimeHookFlags {
    #[must_use]
    pub const fn all_enabled() -> Self {
        Self { suite_hooks: true }
    }

    #[must_use]
    pub const fn all_disabled() -> Self {
        Self { suite_hooks: false }
    }

    #[must_use]
    pub fn from_env() -> Self {
        Self {
            suite_hooks: normalized_env_value(SUITE_HOOKS_ENV)
                .is_some_and(|value| env_value_truthy(&value)),
        }
    }

    #[must_use]
    pub fn resolve(cli_suite_hooks: Option<bool>) -> Self {
        let env = Self::from_env();
        Self {
            suite_hooks: cli_suite_hooks.unwrap_or(env.suite_hooks),
        }
    }
}

fn env_value_truthy(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}
