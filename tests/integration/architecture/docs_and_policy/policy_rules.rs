use std::path::Path;

use super::super::helpers::{collect_hits_in_tree, collect_line_hits_in_tree};

/// Does this line carry a Clippy allow attribute?
///
/// The rule is one predicate: the `allow(clippy::` token must be preceded on
/// the same line by an attribute opener. That covers the plain, inner and
/// `cfg_attr` forms without a comment stripper or a lexer, and prose naming a
/// lint decision has no opener before it so it does not match. `expect` is
/// deliberately untouched - the repo permits `#[expect]`.
///
/// The check is line-based and errs toward reporting: source embedded in a
/// string literal that itself contains an allow attribute is flagged. That
/// direction is on purpose, because a guard that under-detects stops enforcing
/// silently while an over-report announces itself. Split the token the way this
/// file does if such a literal is ever needed.
fn line_has_clippy_allow(line: &str) -> bool {
    // Held as two halves rather than one joined token: it keeps this file from
    // matching its own rule, and it means walking the tree allocates nothing
    // per line. `expect` cannot match either half, so it stays permitted.
    const HEAD: &str = "allow";
    const TAIL: &str = "(clippy::";

    let mut consumed = 0usize;
    while let Some(offset) = line[consumed..].find(HEAD) {
        let position = consumed + offset;
        let after = position + HEAD.len();
        if line[after..].starts_with(TAIL) {
            let prefix = &line[..position];
            if prefix.contains("#[") || prefix.contains("#![") {
                return true;
            }
        }
        consumed = after;
    }

    false
}

#[test]
fn plain_allow_attribute_is_flagged() {
    let token = ["allow", "(clippy::"].concat();
    assert!(line_has_clippy_allow(&format!("#[{token}large_futures)]")));
    assert!(line_has_clippy_allow(&format!("    #[{token}large_futures)]")));
}

#[test]
fn inner_allow_attribute_is_flagged() {
    let token = ["allow", "(clippy::"].concat();
    assert!(line_has_clippy_allow(&format!("#![{token}large_futures)]")));
}

#[test]
fn cfg_attr_wrapped_allow_is_flagged() {
    let token = ["allow", "(clippy::"].concat();
    assert!(line_has_clippy_allow(&format!(
        "#[cfg_attr(target_os = \"linux\", {token}large_futures))]"
    )));
}

#[test]
fn expect_attributes_are_not_flagged() {
    let token = ["expect", "(clippy::"].concat();
    for line in [
        format!("#[{token}large_futures)]"),
        format!("#![{token}large_futures)]"),
        format!("#[cfg_attr(test, {token}large_futures))]"),
    ] {
        assert!(
            !line_has_clippy_allow(&line),
            "expect is permitted: {line}"
        );
    }
}

#[test]
fn prose_naming_the_attribute_is_not_flagged() {
    let token = ["allow", "(clippy::"].concat();
    assert!(!line_has_clippy_allow(&format!(
        "/// retired the blanket `{token}large_futures)` the wrapper carried"
    )));
    assert!(!line_has_clippy_allow(&format!("// see {token}large_futures)")));
}

#[test]
fn source_embedded_in_a_literal_is_flagged_on_purpose() {
    let token = ["allow", "(clippy::"].concat();
    assert!(
        line_has_clippy_allow(&format!("let src = r#\"#[{token}foo)]\"#;")),
        "the line-based check errs toward reporting rather than hiding a real attribute"
    );
}

#[test]
fn repo_contains_no_clippy_allow_attributes() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut hits = Vec::new();

    for start in [root.join("src"), root.join("tests"), root.join("testkit")] {
        hits.extend(collect_line_hits_in_tree(
            &start,
            root,
            None,
            line_has_clippy_allow,
            |path, line_number, line| {
                format!(
                    "{path}:{line_number} carries a forbidden Clippy allow attribute: {}",
                    line.trim()
                )
            },
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
