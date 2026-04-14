use super::*;

#[test]
fn guard_bash_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let guard_bash_mod = fs::read_to_string(root.join("src/hooks/guard_bash/mod.rs")).unwrap();

    for needle in [
        "fn denies_direct_kubectl(",
        "fn allows_plain_echo(",
        "mod tests {",
    ] {
        assert!(
            !guard_bash_mod.contains(needle),
            "src/hooks/guard_bash/mod.rs should stay focused on production hook logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/guard_bash/tests.rs").exists(),
        "guard_bash split test module should exist"
    );
}

#[test]
fn verify_bash_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let verify_bash = fs::read_to_string(root.join("src/hooks/verify_bash.rs")).unwrap();

    for needle in [
        "fn subcommand_artifacts_apply(",
        "fn has_table_rows_with_enough_rows(",
        "mod tests {",
    ] {
        assert!(
            !verify_bash.contains(needle),
            "src/hooks/verify_bash.rs should stay focused on production hook logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/hooks/verify_bash/tests.rs").exists(),
        "verify_bash split test module should exist"
    );
}

#[test]
fn runner_policy_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runner_policy = fs::read_to_string(root.join("src/hooks/runner_policy.rs")).unwrap();

    for needle in [
        "pub enum LegacyScript {",
        "pub enum TaskOutputPattern {",
        "pub enum TrackedHarnessSubcommand {",
        "pub fn managed_cluster_binaries()",
        "pub fn is_manifest_fix_prompt(",
        "pub fn matches_manifest_fix_question(",
        "pub fn classify_canonical_gate(",
    ] {
        assert!(
            !runner_policy.contains(needle),
            "src/hooks/runner_policy.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/hooks/runner_policy/cluster.rs",
        "src/hooks/runner_policy/files.rs",
        "src/hooks/runner_policy/commands.rs",
        "src/hooks/runner_policy/questions.rs",
        "src/hooks/runner_policy/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "runner_policy split module should exist: {path}"
        );
    }
}
