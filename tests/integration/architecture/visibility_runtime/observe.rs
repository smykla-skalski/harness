use super::*;

#[test]
fn observe_output_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = fs::read_to_string(root.join("src/observe/output.rs")).unwrap();

    for needle in [
        "fn human_output_format(",
        "fn json_output_uses_nested_contract(",
        "mod tests {",
    ] {
        assert!(
            !output.contains(needle),
            "src/observe/output.rs should stay focused on production rendering logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/output/tests.rs").exists(),
        "observe output split test module should exist"
    );
}

#[test]
fn observe_types_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let types_mod = fs::read_to_string(root.join("src/observe/types/mod.rs")).unwrap();

    for needle in [
        "pub enum IssueCategory {",
        "pub enum IssueSeverity {",
        "pub enum MessageRole {",
        "pub enum SourceTool {",
        "pub enum Confidence {",
        "pub enum FixSafety {",
        "mod tests {",
    ] {
        assert!(
            !types_mod.contains(needle),
            "src/observe/types/mod.rs should stay focused on production observe types instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/types/classification.rs").exists(),
        "observe types classification split module should exist"
    );
    assert!(
        root.join("src/observe/types/tests.rs").exists(),
        "observe types split test module should exist"
    );
}

#[test]
fn observe_session_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let session = fs::read_to_string(root.join("src/observe/session.rs")).unwrap();

    for needle in [
        "fn find_session_in_temp_dir(",
        "fn find_session_ambiguous_without_hint(",
        "mod tests {",
    ] {
        assert!(
            !session.contains(needle),
            "src/observe/session.rs should stay focused on production session lookup instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/session/tests.rs").exists(),
        "observe session split test module should exist"
    );
}

#[test]
fn observe_registry_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let registry = fs::read_to_string(root.join("src/observe/classifier/registry.rs")).unwrap();

    for needle in [
        "static ISSUE_CODE_REGISTRY:",
        "fn registry_covers_all_codes(",
        "fn issue_owner_display(",
        "mod tests {",
    ] {
        assert!(
            !registry.contains(needle),
            "src/observe/classifier/registry.rs should stay focused on production registry data instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/observe/classifier/registry/tests.rs")
            .exists(),
        "observe classifier registry split test module should exist"
    );
    assert!(
        root.join("src/observe/classifier/registry/data/mod.rs")
            .exists(),
        "observe classifier registry data facade should exist"
    );
    for path in [
        "src/observe/classifier/registry/data/hook.rs",
        "src/observe/classifier/registry/data/build.rs",
        "src/observe/classifier/registry/data/cli.rs",
        "src/observe/classifier/registry/data/integrity.rs",
        "src/observe/classifier/registry/data/skill.rs",
        "src/observe/classifier/registry/data/subagent.rs",
        "src/observe/classifier/registry/data/unexpected.rs",
        "src/observe/classifier/registry/data/user.rs",
        "src/observe/classifier/registry/data/workflow.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "observe classifier registry split module should exist: {path}"
        );
    }
}
