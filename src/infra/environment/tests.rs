use super::*;
use std::env;

#[test]
fn merge_env_leaves_path_unchanged() {
    // REPO_ROOT used to switch on a PATH rewrite that put a locally built
    // kumactl directory in front of every spawned command's lookup.
    let mut extra = HashMap::new();
    extra.insert("REPO_ROOT".into(), "/nonexistent-repo-root".into());
    let original_path = env::var("PATH").unwrap_or_default();
    let merged = merge_env(extra.iter());
    assert_eq!(merged.get("PATH"), Some(&original_path));
}

#[test]
fn merge_env_lets_extras_override_inherited_values() {
    let mut extra = HashMap::new();
    extra.insert("HARNESS_MERGE_ENV_PROBE".into(), "probe".into());
    extra.insert("PATH".into(), "/only-this".into());
    let merged = merge_env(extra.iter());
    assert_eq!(
        merged.get("HARNESS_MERGE_ENV_PROBE").map(String::as_str),
        Some("probe")
    );
    assert_eq!(merged.get("PATH").map(String::as_str), Some("/only-this"));
}
