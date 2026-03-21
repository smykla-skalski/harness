use std::fs;
use std::path::Path;

use super::helpers::{collect_hits_in_tree, matches_extension};

#[test]
fn new_domain_roots_exist() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "ARCHITECTURE.md",
        "src/app",
        "src/run",
        "src/authoring",
        "src/observe",
        "src/setup",
        "src/workspace",
        "src/kernel",
        "src/platform",
        "src/infra",
        "src/hooks",
    ] {
        assert!(root.join(path).exists(), "missing expected path: {path}");
    }
}

#[test]
fn legacy_scatter_roots_are_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "src/commands",
        "src/workflow",
        "src/context",
        "src/run_services",
        "src/prepared_suite",
        "src/bootstrap.rs",
        "src/authoring_validate.rs",
        "src/cluster",
        "src/compose",
        "src/exec",
        "src/io",
        "src/runtime.rs",
        "src/compact",
        "src/core_defs",
        "src/schema",
        "src/rules",
        "src/shell_parse.rs",
        "src/platform/cluster",
    ] {
        assert!(
            !root.join(path).exists(),
            "legacy layout path should not exist anymore: {path}"
        );
    }
}

#[test]
fn cluster_topology_is_owned_by_kernel() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert!(
        root.join("src/kernel/topology.rs").exists(),
        "kernel topology module should exist"
    );

    let platform_mod = fs::read_to_string(root.join("src/platform/mod.rs")).unwrap();
    assert!(
        !platform_mod.contains("pub mod cluster;"),
        "src/platform/mod.rs should not publicly expose a cluster topology module"
    );

    let mut hits = Vec::new();
    for path in [
        "src/run/context/current.rs",
        "src/run/context/aggregate.rs",
        "src/run/application/current.rs",
        "src/run/application/access.rs",
        "src/run/application/preflight.rs",
        "src/run/application/inspection.rs",
        "src/run/application/capture.rs",
        "src/run/application/recording.rs",
        "src/setup/services/cluster.rs",
        "src/setup/capabilities/data.rs",
        "src/setup/capabilities/model.rs",
        "src/setup/cluster/kubernetes/runtime.rs",
        "src/setup/cluster/kubernetes/modes.rs",
        "src/setup/cluster/universal.rs",
        "src/platform/runtime/kubernetes.rs",
        "src/platform/runtime/profile.rs",
        "src/platform/runtime/universal.rs",
        "src/hooks/verify_bash.rs",
        "tests/integration/cluster.rs",
        "tests/integration/universal.rs",
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        if contents.contains("platform::cluster::") {
            hits.push(format!("{path} still depends on platform::cluster"));
        }
        if contents.contains("kernel::topology::") {
            continue;
        }
        hits.push(format!("{path} should depend on kernel::topology"));
    }

    assert!(
        hits.is_empty(),
        "generic cluster topology must be owned by kernel:\n{}",
        hits.join("\n")
    );
}

#[test]
fn platform_compose_root_is_thin() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let compose_mod = fs::read_to_string(root.join("src/platform/compose/mod.rs")).unwrap();

    for needle in [
        "fn bridge_network(",
        "fn cp_env(",
        "fn cp_command(",
        "fn postgres_depends(",
        "mod tests {",
    ] {
        assert!(
            !compose_mod.contains(needle),
            "src/platform/compose/mod.rs should stay focused on compose types and exports instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/compose/tests.rs").exists(),
        "platform compose split test module should exist"
    );
}

#[test]
fn run_specs_root_is_thin() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let specs_mod = fs::read_to_string(root.join("src/run/specs/mod.rs")).unwrap();

    for needle in [
        "fn effective_requires(",
        "fn deserialize_baseline_files(",
        "fn deserialize_skipped_groups(",
        "mod tests {",
    ] {
        assert!(
            !specs_mod.contains(needle),
            "src/run/specs/mod.rs should stay focused on public exports instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/specs/tests.rs").exists(),
        "run specs split test module should exist"
    );
}

#[test]
fn platform_module_stays_internal_to_the_crate() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let lib_rs = fs::read_to_string(root.join("src/lib.rs")).unwrap();
    assert!(
        !lib_rs.contains("pub mod platform;"),
        "src/lib.rs should not expose platform as a public crate surface"
    );
    assert!(
        lib_rs.contains("pub(crate) mod platform;"),
        "src/lib.rs should keep platform crate-internal"
    );

    for path in [
        "tests/integration/universal.rs",
        "tests/integration/preflight.rs",
        "tests/integration/compact.rs",
        "tests/integration/commands/session_stop.rs",
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains("harness::platform::"),
            "{path} should not depend on the internal platform module"
        );
    }
}

#[test]
fn internal_code_uses_kernel_command_intent_instead_of_legacy_shell_parse() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let src_root = root.join("src");
    let mut stack = vec![src_root];
    let mut hits = Vec::new();

    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(&path).unwrap() {
            let entry = entry.unwrap();
            let child = entry.path();
            if child.is_dir() {
                stack.push(child);
                continue;
            }
            if !matches_extension(&child) {
                continue;
            }
            let contents = fs::read_to_string(&child).unwrap();
            if contents.contains("crate::shell_parse") {
                hits.push(format!(
                    "{} still references crate::shell_parse",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "found legacy command-intent imports:\n{}",
        hits.join("\n")
    );
}

#[test]
fn app_context_stays_app_wiring_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let contents = fs::read_to_string(root.join("src/app/command_context.rs")).unwrap();

    for needle in [
        "RunAggregate",
        "RunContext",
        "RunRepository",
        "resolve_run_directory",
        "RunDirArgs",
        "BlockRegistry",
        "shared_blocks(",
        "blocks(",
    ] {
        assert!(
            !contents.contains(needle),
            "src/app/command_context.rs should not own run resolution via `{needle}`"
        );
    }
}

#[test]
fn workspace_session_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let session = fs::read_to_string(root.join("src/workspace/session.rs")).unwrap();

    for needle in ["fn data_root_prefers_xdg_data_home()", "mod tests {"] {
        assert!(
            !session.contains(needle),
            "src/workspace/session.rs should stay focused on production workspace scope logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/workspace/session/tests.rs").exists(),
        "workspace session split test module should exist"
    );
}

#[test]
fn bespoke_frontmatter_paths_are_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let denylist = ["extract_raw_frontmatter(", "serde_yml::Mapping"];
    let hits = collect_hits_in_tree(&root.join("src"), root, None, &denylist, |path, needle| {
        format!("{path} contains forbidden bespoke frontmatter logic `{needle}`")
    });

    assert!(
        hits.is_empty(),
        "found bespoke frontmatter logic after dependency migration:\n{}",
        hits.join("\n")
    );
}
