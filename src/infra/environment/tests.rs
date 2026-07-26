use super::*;
use std::iter;

#[test]
fn merge_env_inherits_path_without_rewriting_it() {
    // REPO_ROOT is what used to switch on the PATH rewrite, so it stays set here
    // to keep this a regression test rather than a vacuous one.
    temp_env::with_vars(
        [
            ("PATH", Some("/sentinel/bin")),
            ("REPO_ROOT", Some("/nonexistent-repo-root")),
        ],
        || {
            let merged = merge_env(iter::empty());
            assert_eq!(
                merged.get("PATH").map(String::as_str),
                Some("/sentinel/bin")
            );
        },
    );
}

#[test]
fn merge_env_omits_path_when_the_process_has_none() {
    temp_env::with_vars(
        [
            ("PATH", None),
            ("REPO_ROOT", Some("/nonexistent-repo-root")),
        ],
        || {
            let merged = merge_env(iter::empty());
            assert_eq!(merged.get("PATH"), None);
        },
    );
}

#[test]
fn merge_env_lets_extras_override_inherited_values() {
    temp_env::with_var("PATH", Some("/sentinel/bin"), || {
        let mut extra = HashMap::new();
        extra.insert("HARNESS_MERGE_ENV_PROBE".into(), "probe".into());
        extra.insert("PATH".into(), "/only-this".into());
        let merged = merge_env(extra.iter());
        assert_eq!(
            merged.get("HARNESS_MERGE_ENV_PROBE").map(String::as_str),
            Some("probe")
        );
        assert_eq!(merged.get("PATH").map(String::as_str), Some("/only-this"));
    });
}
