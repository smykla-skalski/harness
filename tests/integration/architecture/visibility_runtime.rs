use std::fs;
use std::path::Path;

fn assert_split_modules_exist(root: &Path, paths: &[&str], message: &str) {
    for path in paths {
        assert!(root.join(path).exists(), "{message}: {path}");
    }
}

#[test]
fn docker_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let docker_mod = fs::read_to_string(root.join("src/infra/blocks/docker/mod.rs")).unwrap();

    for needle in [
        "impl ContainerRuntime for DockerContainerRuntime",
        "struct FakeContainer {",
        "pub struct FakeContainerRuntime {",
        "mod tests {",
    ] {
        assert!(
            !docker_mod.contains(needle),
            "src/infra/blocks/docker/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/docker/runtime.rs",
        "src/infra/blocks/docker/fake.rs",
        "src/infra/blocks/docker/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "docker block split module should exist: {path}"
        );
    }
}

#[test]
fn compose_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let compose_mod = fs::read_to_string(root.join("src/infra/blocks/compose/mod.rs")).unwrap();

    for needle in [
        "pub struct DockerComposeOrchestrator",
        "pub struct FakeComposeOrchestrator",
        "mod tests {",
    ] {
        assert!(
            !compose_mod.contains(needle),
            "src/infra/blocks/compose/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/compose/runtime.rs",
        "src/infra/blocks/compose/fake.rs",
        "src/infra/blocks/compose/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "compose block split module should exist: {path}"
        );
    }
}

#[test]
fn helm_block_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let helm = fs::read_to_string(root.join("src/infra/blocks/helm.rs")).unwrap();

    for needle in [
        "pub struct HelmSetting {",
        "pub struct HelmDeployer {",
        "pub struct FakePackageDeployer {",
        "fn helm_setting_parses_cli_arg(",
        "fn fake_package_deployer_tracks_release_state(",
        "mod tests {",
    ] {
        assert!(
            !helm.contains(needle),
            "src/infra/blocks/helm.rs should stay focused on production Helm deployment behavior instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/blocks/helm/tests.rs").exists(),
        "helm block split test module should exist"
    );
    for path in [
        "src/infra/blocks/helm/contract.rs",
        "src/infra/blocks/helm/runtime.rs",
        "src/infra/blocks/helm/fake.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "helm block split module should exist: {path}"
        );
    }
}

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
fn setup_capabilities_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let capabilities = fs::read_to_string(root.join("src/setup/capabilities.rs")).unwrap();

    for needle in [
        "pub enum Feature {",
        "fn core_features()",
        "fn operational_features()",
        "fn capabilities_returns_zero(",
        "fn feature_count_is_current(",
        "mod tests {",
    ] {
        assert!(
            !capabilities.contains(needle),
            "src/setup/capabilities.rs should stay focused on production capability modeling instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/capabilities/tests.rs").exists(),
        "setup capabilities split test module should exist"
    );
    for path in [
        "src/setup/capabilities/model.rs",
        "src/setup/capabilities/data.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "setup capabilities split module should exist: {path}"
        );
    }
}

#[test]
fn setup_build_info_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let build_info = fs::read_to_string(root.join("src/setup/build_info.rs")).unwrap();

    for needle in ["fn build_info_env(", "mod tests {"] {
        assert!(
            !build_info.contains(needle),
            "src/setup/build_info.rs should stay focused on production build-info resolution instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/build_info/tests.rs").exists(),
        "setup build_info split test module should exist"
    );
}

#[test]
fn setup_gateway_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let gateway = fs::read_to_string(root.join("src/setup/gateway.rs")).unwrap();

    for needle in [
        "fn detect_version_parses_standard_entry()",
        "fn install_url_embeds_arbitrary_version()",
        "mod tests {",
    ] {
        assert!(
            !gateway.contains(needle),
            "src/setup/gateway.rs should stay focused on production gateway setup instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/gateway/tests.rs").exists(),
        "setup gateway split test module should exist"
    );
}

#[test]
fn authoring_workflow_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/authoring/workflow.rs")).unwrap();

    for needle in [
        "fn author_phase_display(",
        "fn approval_mode_serialization(",
        "mod tests {",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/authoring/workflow.rs should stay focused on production workflow logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/authoring/workflow/tests.rs").exists(),
        "authoring workflow split test module should exist"
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
fn run_workflow_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = fs::read_to_string(root.join("src/run/workflow/mod.rs")).unwrap();

    for needle in [
        "fn runner_phase_display(",
        "fn apply_event_cluster_prepared_advances_to_preflight(",
        "mod tests {",
    ] {
        assert!(
            !workflow.contains(needle),
            "src/run/workflow/mod.rs should stay focused on production workflow logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/workflow/tests.rs").exists(),
        "run workflow split test module should exist"
    );
}

#[test]
fn run_task_output_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let task_output = fs::read_to_string(root.join("src/run/services/task_output.rs")).unwrap();

    for needle in [
        "fn extract_plain_text_line(",
        "fn extract_skips_user_messages(",
        "mod tests {",
    ] {
        assert!(
            !task_output.contains(needle),
            "src/run/services/task_output.rs should stay focused on production task-output parsing instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/services/task_output/tests.rs").exists(),
        "run task_output split test module should exist"
    );
}

#[test]
fn app_cli_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cli = fs::read_to_string(root.join("src/app/cli.rs")).unwrap();

    for needle in [
        "fn all_expected_subcommands_registered(",
        "fn parse_init_command(",
        "mod tests {",
    ] {
        assert!(
            !cli.contains(needle),
            "src/app/cli.rs should stay focused on production CLI transport instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/app/cli/tests.rs").exists(),
        "app cli split test module should exist"
    );
}

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
        "fn render_format_displays_stable_names(",
        "fn focus_presets_static(",
        "mod tests {",
    ] {
        assert!(
            !types_mod.contains(needle),
            "src/observe/types/mod.rs should stay focused on production observe types instead of owning `{needle}`"
        );
    }

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
fn run_prepared_suite_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let prepared_suite = fs::read_to_string(root.join("src/run/prepared_suite/mod.rs")).unwrap();

    for needle in [
        "fn prepared_suite_digests_tracking_defaults(",
        "fn to_json_includes_group_source_paths_and_manifest_metadata(",
        "mod tests {",
    ] {
        assert!(
            !prepared_suite.contains(needle),
            "src/run/prepared_suite/mod.rs should stay focused on production prepared-suite logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/prepared_suite/tests.rs").exists(),
        "run prepared_suite split test module should exist"
    );
}

#[test]
fn run_validated_layout_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let validated = fs::read_to_string(root.join("src/run/context/validated.rs")).unwrap();

    for needle in [
        "fn validated_layout_succeeds_for_existing_dir(",
        "fn validated_layout_into_inner_returns_original(",
        "mod tests {",
    ] {
        assert!(
            !validated.contains(needle),
            "src/run/context/validated.rs should stay focused on production validated-layout behavior instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/context/validated/tests.rs").exists(),
        "run validated-layout split test module should exist"
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
        root.join("src/observe/classifier/registry/data.rs")
            .exists(),
        "observe classifier registry data module should exist"
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

#[test]
fn platform_runtime_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runtime = fs::read_to_string(root.join("src/platform/runtime.rs")).unwrap();

    for needle in [
        "pub struct ControlPlaneAccess<'a>",
        "pub struct KubernetesRuntime<'a>",
        "pub struct UniversalRuntime<'a>",
        "fn universal_runtime_exposes_control_plane_access(",
        "fn profile_platform_detects_universal_variants(",
        "mod tests {",
    ] {
        assert!(
            !runtime.contains(needle),
            "src/platform/runtime.rs should stay focused on production runtime access instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/runtime/tests.rs").exists(),
        "platform runtime split test module should exist"
    );
    for path in [
        "src/platform/runtime/access.rs",
        "src/platform/runtime/kubernetes.rs",
        "src/platform/runtime/universal.rs",
        "src/platform/runtime/profile.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "platform runtime split module should exist: {path}"
        );
    }
}

#[test]
fn platform_ephemeral_metallb_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let metallb = fs::read_to_string(root.join("src/platform/ephemeral_metallb.rs")).unwrap();

    for needle in [
        "fn state_path_includes_state_dir(",
        "fn ensure_templates_fails_when_no_source(",
        "mod tests {",
    ] {
        assert!(
            !metallb.contains(needle),
            "src/platform/ephemeral_metallb.rs should stay focused on production template state handling instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/platform/ephemeral_metallb/tests.rs")
            .exists(),
        "platform ephemeral_metallb split test module should exist"
    );
}

#[test]
fn kubernetes_block_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let kubernetes_mod = fs::read_to_string(root.join("src/infra/blocks/kubernetes.rs")).unwrap();

    for needle in [
        "serde_json::from_str(&result.stdout)",
        "containerStatuses",
        "pub struct FakeKubernetesOperator {",
        "pub struct FakeLocalClusterManager {",
        "mod tests {",
    ] {
        assert!(
            !kubernetes_mod.contains(needle),
            "src/infra/blocks/kubernetes.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/infra/blocks/kubernetes/fake.rs",
        "src/infra/blocks/kubernetes/pods.rs",
        "src/infra/blocks/kubernetes/tests.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "kubernetes block split module should exist: {path}"
        );
    }
}

#[test]
fn setup_universal_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let universal_mod = fs::read_to_string(root.join("src/setup/cluster/universal.rs")).unwrap();

    for needle in [
        "fn universal_single_up(",
        "fn universal_global_zone_up(",
        "fn universal_global_two_zones_up(",
    ] {
        assert!(
            !universal_mod.contains(needle),
            "src/setup/cluster/universal.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    for path in [
        "src/setup/cluster/universal/config.rs",
        "src/setup/cluster/universal/runtime.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "setup universal split module should exist: {path}"
        );
    }
}

#[test]
fn setup_universal_runtime_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let runtime = fs::read_to_string(root.join("src/setup/cluster/universal/runtime.rs")).unwrap();

    for needle in [
        "fn universal_single_up_compose(",
        "fn universal_global_zone_up(",
        "fn universal_global_two_zones_up(",
        "mod tests {",
    ] {
        assert!(
            !runtime.contains(needle),
            "src/setup/cluster/universal/runtime.rs should stay focused on runtime dispatch instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/setup/cluster/universal/runtime/compose.rs")
            .exists(),
        "setup universal runtime compose split module should exist"
    );
}

#[test]
fn run_services_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_services = fs::read_to_string(root.join("src/run/services/mod.rs")).unwrap();

    for needle in [
        "fn write_suite(",
        "fn prepare_preflight_run(",
        "mod tests {",
    ] {
        assert!(
            !run_services.contains(needle),
            "src/run/services/mod.rs should stay a thin facade instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/services/tests.rs").exists(),
        "run services split test module should exist"
    );
}

#[test]
fn run_audit_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_audit = fs::read_to_string(root.join("src/run/audit/mod.rs")).unwrap();

    for needle in [
        "fn sample_status(",
        "fn assert_audit_entry_fields(",
        "mod tests {",
    ] {
        assert!(
            !run_audit.contains(needle),
            "src/run/audit/mod.rs should stay focused on production audit logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/audit/tests.rs").exists(),
        "run audit split test module should exist"
    );
}

#[test]
fn versioned_json_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let versioned_json =
        fs::read_to_string(root.join("src/infra/persistence/versioned_json.rs")).unwrap();

    for needle in [
        "fn load_returns_none_when_file_missing(",
        "fn update_serializes_concurrent_writers(",
        "mod tests {",
    ] {
        assert!(
            !versioned_json.contains(needle),
            "src/infra/persistence/versioned_json.rs should stay focused on production persistence logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/persistence/versioned_json/tests.rs")
            .exists(),
        "versioned json split test module should exist"
    );
}

#[test]
fn run_resolve_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let resolve_mod = fs::read_to_string(root.join("src/run/resolve.rs")).unwrap();

    for needle in [
        "fn resolve_run_directory_with_existing_dir()",
        "fn resolve_manifest_path_leading_slash_treated_as_relative()",
        "mod tests {",
    ] {
        assert!(
            !resolve_mod.contains(needle),
            "src/run/resolve.rs should stay focused on production resolution logic instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/resolve/tests.rs").exists(),
        "run resolve split test module should exist"
    );
}

#[test]
fn run_state_capture_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let state_capture = fs::read_to_string(root.join("src/run/state_capture.rs")).unwrap();

    for needle in [
        "fn dataplane_collection_extracts_known_fields()",
        "fn dataplane_snapshot_reads_nested_meta_fields()",
        "mod tests {",
    ] {
        assert!(
            !state_capture.contains(needle),
            "src/run/state_capture.rs should stay focused on production capture types instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/run/state_capture/tests.rs").exists(),
        "run state_capture split test module should exist"
    );
}

#[test]
fn infra_io_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let infra_io = fs::read_to_string(root.join("src/infra/io/mod.rs")).unwrap();

    for needle in [
        "fn write_and_read_json(",
        "fn append_markdown_row_appends_to_existing(",
        "mod tests {",
    ] {
        assert!(
            !infra_io.contains(needle),
            "src/infra/io/mod.rs should stay focused on production io helpers instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/infra/io/tests.rs").exists(),
        "infra io split test module should exist"
    );
}
