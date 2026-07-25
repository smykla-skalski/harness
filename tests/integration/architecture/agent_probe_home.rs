use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// Spawned test binaries are not `cfg(test)` builds, so their agent probe home
/// falls back to the OS account home. Setting only `HOME` on the child leaves
/// package downloads landing in the developer's real home, which is how 150G of
/// Copilot caches once leaked. `env_isolated_home` sets both.
#[test]
fn spawned_test_binaries_never_set_home_without_isolating_the_probe_home() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("tests"),
        root,
        Some(&root.join("tests/integration/architecture/agent_probe_home.rs")),
        &[r#".env("HOME""#],
        |path, needle| format!("{path} sets the child home with `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "tests must spawn children with `harness_testkit::CommandEnvExt::env_isolated_home`, \
         which also redirects the agent probe home away from the real account home:\n{}",
        hits.join("\n")
    );
}
