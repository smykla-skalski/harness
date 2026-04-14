use super::*;

#[test]
fn codec_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let codec = fs::read_to_string(root.join("src/codec.rs")).unwrap();

    for needle in [
        "fn test_from_mapping_basic()",
        "fn test_from_mapping_with_defaults()",
        "mod tests {",
    ] {
        assert!(
            !codec.contains(needle),
            "src/codec.rs should stay focused on production codec helpers instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/codec/tests.rs").exists(),
        "codec split test module should exist"
    );
}

#[test]
fn manifests_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let manifests = fs::read_to_string(root.join("src/manifests.rs")).unwrap();

    for needle in [
        "fn default_validation_output_changes_extension(",
        "fn default_validation_output_no_extension(",
        "mod tests {",
    ] {
        assert!(
            !manifests.contains(needle),
            "src/manifests.rs should stay focused on production manifest helpers instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/manifests/tests.rs").exists(),
        "manifests split test module should exist"
    );
}

#[test]
fn create_workflow_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/create/workflow.rs")).unwrap();

    for needle in [
        "fn create_phase_display(",
        "fn approval_mode_serialization(",
        "mod tests {",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/create/workflow.rs should stay focused on production workflow logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/create/workflow/tests.rs").exists(),
        "create workflow split test module should exist"
    );
}

#[test]
fn kernel_topology_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let topology = fs::read_to_string(root.join("src/kernel/topology.rs")).unwrap();

    for needle in [
        "fn platform_display_roundtrip(",
        "fn current_deploy_round_trip(",
        "pub enum Platform {",
        "pub enum ClusterMode {",
        "pub struct ClusterSpec {",
        "pub fn from_object(",
        "pub fn from_mode_with_platform(",
        "CurrentDeployPayload",
        "mod tests {",
    ] {
        assert!(
            !topology.contains(needle),
            "src/kernel/topology.rs should stay focused on production topology logic instead of owning `{needle}`"
        );
    }

    assert_split_modules_exist(
        root,
        &[
            "src/kernel/topology/tests.rs",
            "src/kernel/topology/parsing.rs",
            "src/kernel/topology/current_deploy.rs",
            "src/kernel/topology/model.rs",
            "src/kernel/topology/spec.rs",
        ],
        "kernel topology split module should exist",
    );
}

#[test]
fn suite_defaults_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let defaults = fs::read_to_string(root.join("src/suite_defaults.rs")).unwrap();

    for needle in [
        "mod tests {",
        "fn write_and_load_suite_defaults_no_repo_root(",
    ] {
        assert!(
            !defaults.contains(needle),
            "src/suite_defaults.rs should stay focused on production defaults logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/suite_defaults/tests.rs").exists(),
        "suite_defaults split test module should exist"
    );
}

#[test]
fn workspace_paths_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let paths = fs::read_to_string(root.join("src/workspace/paths.rs")).unwrap();

    for needle in [
        "fn utc_now_ends_with_z()",
        "fn dirs_home_prefers_home_env()",
        "mod tests {",
    ] {
        assert!(
            !paths.contains(needle),
            "src/workspace/paths.rs should stay focused on production path helpers instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/workspace/paths/tests.rs").exists(),
        "workspace paths split test module should exist"
    );
}
