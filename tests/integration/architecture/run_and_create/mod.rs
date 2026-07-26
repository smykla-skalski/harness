use std::fs;
use std::path::Path;

use super::helpers::{
    assert_file_contains_needles, assert_file_lacks_needles, collect_hits_in_paths, read_repo_file,
    repo_path_exists,
};

mod create_boundary;

#[test]
fn run_domain_does_not_depend_on_block_registry() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_root = root.join("src/run");
    let mut stack = vec![run_root];
    let mut hits = Vec::new();

    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(&path).unwrap() {
            let entry = entry.unwrap();
            let child = entry.path();
            if child.is_dir() {
                stack.push(child);
                continue;
            }
            if child.extension().and_then(|ext| ext.to_str()) != Some("rs") {
                continue;
            }
            let contents = fs::read_to_string(&child).unwrap();
            if contents.contains("BlockRegistry") {
                hits.push(format!(
                    "{} still depends on BlockRegistry instead of explicit run-owned dependencies",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "run domain should not depend on infra::blocks::BlockRegistry anymore:\n{}",
        hits.join("\n")
    );
}

#[test]
fn run_context_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let context_mod = read_repo_file(root, "src/run/context/mod.rs");

    for needle in [
        "pub struct RunLayout",
        "pub struct RunMetadata",
        "pub struct CommandEnv",
        "pub struct PreflightArtifact",
        "pub struct CurrentRunPointer",
        "impl RunLayout",
        "impl CommandEnv",
        "impl CurrentRunPointer",
        "mod tests {",
    ] {
        assert!(
            !context_mod.contains(needle),
            "src/run/context/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/run/context/layout.rs",
        "src/run/context/metadata.rs",
        "src/run/context/command_env.rs",
        "src/run/context/preflight.rs",
        "src/run/context/current.rs",
        "src/run/context/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "run/context split module should exist: {path}"
        );
    }
}

#[test]
fn run_application_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let application_mod = read_repo_file(root, "src/run/application/mod.rs");

    for needle in [
        "pub fn current_run_dir()",
        "pub fn from_current()",
        "pub fn cluster_spec(&self)",
        "pub fn list_managed_service_containers()",
        "pub fn remove_managed_service_container(",
    ] {
        assert!(
            !application_mod.contains(needle),
            "src/run/application/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in ["src/run/application/current.rs"] {
        assert!(
            repo_path_exists(root, path),
            "run/application split module should exist: {path}"
        );
    }
}

#[test]
fn run_small_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/run/context/cleanup.rs",
            &[
                "fn new_manifest_is_empty()",
                "fn deserialization_from_json()",
                "mod tests {",
            ][..],
            "src/run/context/cleanup/tests.rs",
        ),
        (
            "src/run/status.rs",
            &[
                "fn test_load_run_status()",
                "fn test_load_run_status_accepts_structured_group_entries()",
                "mod tests {",
            ][..],
            "src/run/status/tests.rs",
        ),
        (
            "src/run/workflow/persistence.rs",
            &[
                "fn read_runner_state_rejects_legacy_flat_state()",
                "fn write_runner_state_if_current_rejects_conflict()",
                "mod tests {",
            ][..],
            "src/run/workflow/persistence/tests.rs",
        ),
    ] {
        let contents = read_repo_file(root, path);
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production run logic instead of owning `{needle}`"
            );
        }
        assert!(
            repo_path_exists(root, split_path),
            "run split test module should exist: {split_path}"
        );
    }
}
