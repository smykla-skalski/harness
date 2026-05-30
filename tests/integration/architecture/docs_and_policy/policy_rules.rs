use std::path::Path;

use super::super::helpers::collect_hits_in_tree;

#[test]
fn repo_contains_no_clippy_allow_attributes() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let needle = ["allow", "(clippy::"].concat();
    let mut hits = Vec::new();

    for start in [root.join("src"), root.join("tests"), root.join("testkit")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &[needle.as_str()],
            |path, matched| format!("{path} still contains forbidden Clippy allow `{matched}`"),
        ));
    }

    assert!(
        hits.is_empty(),
        "found forbidden Clippy allow attributes:\n{}",
        hits.join("\n")
    );
}

#[test]
fn repo_contains_no_custom_macro_rules() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut hits = Vec::new();
    let needle = ["macro", "_rules!"].concat();

    for start in [root.join("src"), root.join("tests"), root.join("testkit")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &[needle.as_str()],
            |path, matched| format!("{path} still contains forbidden custom macro `{matched}`"),
        ));
    }

    assert!(
        hits.is_empty(),
        "found forbidden custom macros:\n{}",
        hits.join("\n")
    );
}

/// Tests must clean up only the child processes they spawn (via the tracked
/// `ManagedChild` PID), never quit or kill applications by name. Driving an
/// app-control script or a name-pattern process killer from a test teardown
/// tears down the developer's own running apps (e.g. a live Harness Monitor)
/// and blocks on AppleEvent timeouts. Guard the test tree against it.
#[test]
fn tests_do_not_quit_or_kill_apps_by_name() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let needles = [
        ["osa", "script"].concat(),
        ["pk", "ill"].concat(),
        ["kill", "all"].concat(),
        ["tell appl", "ication"].concat(),
    ];
    let needle_refs: Vec<&str> = needles.iter().map(String::as_str).collect();
    let mut hits = Vec::new();

    for start in [root.join("tests"), root.join("testkit")] {
        hits.extend(collect_hits_in_tree(
            &start,
            root,
            None,
            &needle_refs,
            |path, matched| {
                format!("{path} controls apps by name via `{matched}`; tests may only stop their own spawned child PIDs")
            },
        ));
    }

    assert!(
        hits.is_empty(),
        "found tests that quit or kill apps by name:\n{}",
        hits.join("\n")
    );
}
