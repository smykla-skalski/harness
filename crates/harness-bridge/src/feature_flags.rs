pub use harness_hook::feature_flags::{RuntimeHookFlags, SUITE_HOOKS_ENV};

pub const ACP_ENV: &str = "HARNESS_FEATURE_ACP";

#[must_use]
pub fn acp_enabled_from_env() -> bool {
    crate::workspace::normalized_env_value(ACP_ENV).is_none_or(|value| env_value_truthy(&value))
}

fn env_value_truthy(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}
