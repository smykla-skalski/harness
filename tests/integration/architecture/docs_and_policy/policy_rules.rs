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
