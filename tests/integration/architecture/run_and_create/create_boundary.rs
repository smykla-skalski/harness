use std::fs;
use std::path::Path;

use super::{
    assert_file_contains_needles, assert_file_lacks_needles, collect_hits_in_paths, read_repo_file,
    repo_path_exists,
};

#[test]
fn create_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let create = read_repo_file(root, "src/create/mod.rs");

    for needle in [
        "fn suite_path_joins_suite_md()",
        "fn schema_summary_serialization()",
        "mod tests {",
    ] {
        assert!(
            !create.contains(needle),
            "src/create/mod.rs should stay focused on create exports instead of owning `{needle}`"
        );
    }

    assert!(
        repo_path_exists(root, "src/create/tests.rs"),
        "create split test module should exist"
    );
}

#[test]
fn create_commands_depend_on_application_boundary() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let commands_root = root.join("src/create/commands");
    let denylist = [
        "crate::create::create_workspace_dir",
        "crate::create::load_create_session",
        "crate::create::require_create_session",
        "crate::create::begin_create_session",
        "crate::create::validate::",
        "crate::create::workflow::",
        "super::shared::",
    ];
    let mut hits = Vec::new();

    for entry in fs::read_dir(&commands_root).unwrap() {
        let entry = entry.unwrap();
        let child = entry.path();
        if child.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let contents = fs::read_to_string(&child).unwrap();
        for needle in denylist {
            if contents.contains(needle) {
                hits.push(format!(
                    "{} still bypasses src/create/application via `{needle}`",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "create commands must route through src/create/application:\n{}",
        hits.join("\n")
    );
}

#[test]
fn create_exposes_a_facade_instead_of_public_internal_modules() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let create_mod = read_repo_file(root, "src/create/mod.rs");
    assert_file_lacks_needles(
        &create_mod,
        "src/create/mod.rs should not publicly expose internal module",
        &["pub mod rules;", "pub mod validate;", "pub mod workflow;"],
    );
    assert_file_contains_needles(
        &create_mod,
        "src/create/mod.rs should expose the create facade via",
        &[
            "pub use workflow::{",
            "pub use session::{",
            "pub use validate::{",
            "pub use rules::{",
        ],
    );

    let hits = collect_hits_in_paths(
        root,
        &[
            "src/hooks/application/context.rs",
            "src/hooks/guard_question.rs",
            "src/hooks/guard_stop.rs",
            "src/hooks/guard_write.rs",
            "tests/integration/commands/record.rs",
        ],
        &[
            "crate::create::workflow::",
            "crate::create::validate::",
            "crate::create::session::",
            "crate::create::rules::",
            "harness::create::workflow::",
        ],
        |path, needle| format!("{path} still depends on create internals via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "create callers should depend on the root facade instead of internal modules:\n{}",
        hits.join("\n")
    );
}
