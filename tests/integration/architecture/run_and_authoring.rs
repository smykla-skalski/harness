use std::fs;
use std::path::Path;

use super::helpers::{
    assert_file_contains_needles, assert_file_lacks_needles, collect_hits_in_paths, read_repo_file,
};

#[test]
fn run_commands_depend_on_application_boundary_not_services() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let commands_root = root.join("src/run/commands");
    let denylist = [
        "use crate::run::services::{",
        "use crate::run::services::StartServiceRequest",
        "use crate::run::services::RecordCommandRequest",
        "use crate::run::services::tail_task_output",
        "use crate::run::services::wait_for_task_output",
        "super::shared::resolve_run_services",
        "super::shared::resolve_run_services_with_blocks",
        "ctx.shared_blocks()",
        "ctx.blocks()",
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
                    "{} still depends on legacy run services via `{needle}`",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "run commands must route through src/run/application:\n{}",
        hits.join("\n")
    );
}

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
    let context_mod = fs::read_to_string(root.join("src/run/context/mod.rs")).unwrap();

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
            root.join(path).exists(),
            "run/context split module should exist: {path}"
        );
    }
}

#[test]
fn run_application_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let application_mod = fs::read_to_string(root.join("src/run/application/mod.rs")).unwrap();

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

    for path in [
        "src/run/application/current.rs",
        "src/run/application/access.rs",
        "src/run/application/managed_services.rs",
    ] {
        assert!(
            root.join(path).exists(),
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
            "src/run/application/dependencies.rs",
            &[
                "fn production_support_includes_core_run_blocks()",
                "fn validate_requirement_names_reports_missing_block()",
                "mod tests {",
            ][..],
            "src/run/application/dependencies/tests.rs",
        ),
        (
            "src/run/services/reporting.rs",
            &[
                "fn last_group_capture_value_empty_groups()",
                "fn warn_if_capture_missing_capture_changed()",
                "mod tests {",
            ][..],
            "src/run/services/reporting/tests.rs",
        ),
        (
            "src/run/application/recording.rs",
            &[
                "fn validate_gid_usage_requires_gid_for_execution_phase()",
                "fn log_group_id_uses_dash_outside_execution_phase()",
                "mod tests {",
            ][..],
            "src/run/application/recording/tests.rs",
        ),
        (
            "src/run/audit/scrub.rs",
            &[
                "fn scrubs_pem_certificate()",
                "fn scrubs_multiple_patterns_in_one_pass()",
                "mod tests {",
            ][..],
            "src/run/audit/scrub/tests.rs",
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
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production run logic instead of owning `{needle}`"
            );
        }
        assert!(
            root.join(split_path).exists(),
            "run split test module should exist: {split_path}"
        );
    }
}

#[test]
fn run_command_roots_stay_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needles, split_path) in [
        (
            "src/run/commands/api.rs",
            &[
                "fn parse_json_body_valid()",
                "fn method_run_dir_and_path_delete()",
                "mod tests {",
            ][..],
            "src/run/commands/api/tests.rs",
        ),
        (
            "src/run/commands/apply.rs",
            &[
                "fn kuma_api_path_mesh_resource()",
                "fn kuma_api_path_defaults_to_default_mesh()",
                "mod tests {",
            ][..],
            "src/run/commands/apply/tests.rs",
        ),
        (
            "src/run/commands/closeout.rs",
            &[
                "fn compute_verdict_all_passed()",
                "fn compute_verdict_no_groups()",
                "mod tests {",
            ][..],
            "src/run/commands/closeout/tests.rs",
        ),
        (
            "src/run/commands/cluster_check.rs",
            &[
                "fn cluster_check_errors_on_nonexistent_run_dir()",
                "mod tests {",
            ][..],
            "src/run/commands/cluster_check/tests.rs",
        ),
        (
            "src/run/commands/logs.rs",
            &[
                "fn resolve_direct_container_single_zone()",
                "fn resolve_service_container_passthrough()",
                "mod tests {",
            ][..],
            "src/run/commands/logs/tests.rs",
        ),
        (
            "src/run/commands/service.rs",
            &[
                "fn resolve_image_explicit_wins()",
                "fn resolve_image_errors_when_no_cp_image()",
                "mod tests {",
            ][..],
            "src/run/commands/service/tests.rs",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        for needle in needles {
            assert!(
                !contents.contains(needle),
                "{path} should stay focused on production command logic instead of owning `{needle}`"
            );
        }
        assert!(
            root.join(split_path).exists(),
            "run command split test module should exist: {split_path}"
        );
    }
}

#[test]
fn authoring_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let authoring = fs::read_to_string(root.join("src/authoring/mod.rs")).unwrap();

    for needle in [
        "fn suite_path_joins_suite_md()",
        "fn schema_summary_serialization()",
        "mod tests {",
    ] {
        assert!(
            !authoring.contains(needle),
            "src/authoring/mod.rs should stay focused on authoring exports instead of owning `{needle}`"
        );
    }

    assert!(
        root.join("src/authoring/tests.rs").exists(),
        "authoring split test module should exist"
    );
}

#[test]
fn run_services_do_not_load_their_own_context() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let contents = fs::read_to_string(root.join("src/run/services/mod.rs")).unwrap();

    for needle in [
        "pub struct RunServices",
        "pub fn from_context(",
        "pub fn from_run_dir(",
        "pub fn from_current(",
        "pub fn context(",
        "pub fn layout(",
        "pub fn metadata(",
        "pub fn status(",
        "pub fn status_mut(",
        "pub fn validate_requirement_names(",
        "pub fn cluster_spec(",
        "pub fn cluster_runtime(",
        "pub fn resolve_kubeconfig(",
        "pub fn control_plane_access(",
        "pub fn xds_access(",
        "pub fn docker_network(",
        "pub fn resolve_container_name(",
        "pub fn service_image(",
        "pub fn call_control_plane_text(",
        "pub fn call_control_plane_json(",
    ] {
        assert!(
            !contents.contains(needle),
            "src/run/services/mod.rs should stay an internal helper layer, not a public run boundary via `{needle}`"
        );
    }
}

#[test]
fn run_services_do_not_own_preflight_application_flows() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let services = fs::read_to_string(root.join("src/run/services/mod.rs")).unwrap();

    for needle in [
        "pub fn suite_spec(",
        "pub fn build_preflight_plan(",
        "pub fn save_preflight_outputs(",
        "pub fn mark_manifest_applied(",
        "pub fn record_preflight_complete(",
        "fn build_preflight_artifact(",
    ] {
        assert!(
            !services.contains(needle),
            "src/run/services/mod.rs should not own preflight application flow `{needle}`"
        );
    }

    let preflight = fs::read_to_string(root.join("src/run/application/preflight.rs")).unwrap();
    for needle in [
        "pub fn suite_spec(",
        "pub fn build_preflight_plan(",
        "pub fn save_preflight_outputs(",
        "pub fn mark_manifest_applied(",
        "pub fn record_preflight_complete(",
    ] {
        assert!(
            preflight.contains(needle),
            "src/run/application/preflight.rs should own `{needle}`"
        );
    }
}

#[test]
fn run_services_do_not_own_capture_application_flow() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let services = fs::read_to_string(root.join("src/run/services/mod.rs")).unwrap();

    for needle in [
        "pub fn capture_state(",
        "fn build_capture_snapshot(",
        "fn capture_kubernetes_snapshot(",
        "fn capture_universal_snapshot(",
    ] {
        assert!(
            !services.contains(needle),
            "src/run/services/mod.rs should not own capture application flow `{needle}`"
        );
    }

    let capture = fs::read_to_string(root.join("src/run/application/capture.rs")).unwrap();
    for needle in [
        "pub fn capture_state(",
        "fn build_capture_snapshot(",
        "fn capture_kubernetes_snapshot(",
        "fn capture_universal_snapshot(",
    ] {
        assert!(
            capture.contains(needle),
            "src/run/application/capture.rs should own `{needle}`"
        );
    }
}

#[test]
fn run_services_do_not_own_cluster_inspection_reports() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let cluster_health =
        fs::read_to_string(root.join("src/run/services/cluster_health.rs")).unwrap();
    let status = fs::read_to_string(root.join("src/run/services/status.rs")).unwrap();

    for (contents, label, needle) in [
        (
            &cluster_health,
            "src/run/services/cluster_health.rs",
            "impl RunServices",
        ),
        (
            &cluster_health,
            "src/run/services/cluster_health.rs",
            "pub fn cluster_health_report(",
        ),
        (&status, "src/run/services/status.rs", "impl RunServices"),
        (
            &status,
            "src/run/services/status.rs",
            "pub fn status_report(",
        ),
    ] {
        assert!(
            !contents.contains(needle),
            "{label} should not own application-facing inspection flow `{needle}`"
        );
    }

    let inspection = fs::read_to_string(root.join("src/run/application/inspection.rs")).unwrap();
    for needle in ["pub fn cluster_health_report(", "pub fn status_report("] {
        assert!(
            inspection.contains(needle),
            "src/run/application/inspection.rs should own `{needle}`"
        );
    }
}

#[test]
fn run_services_do_not_own_service_lifecycle_application_flows() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let lifecycle = fs::read_to_string(root.join("src/run/services/service_lifecycle.rs")).unwrap();

    for needle in [
        "impl RunServices",
        "pub fn list_service_containers(",
        "pub fn start_service(",
        "pub fn service_logs(",
    ] {
        assert!(
            !lifecycle.contains(needle),
            "src/run/services/service_lifecycle.rs should not own application-facing service flow `{needle}`"
        );
    }

    let application = fs::read_to_string(root.join("src/run/application/services.rs")).unwrap();
    for needle in [
        "pub fn list_service_containers(",
        "pub fn start_service(",
        "pub fn service_logs(",
    ] {
        assert!(
            application.contains(needle),
            "src/run/application/services.rs should own `{needle}`"
        );
    }
}

#[test]
fn run_services_do_not_own_group_reporting_application_flow() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let reporting = fs::read_to_string(root.join("src/run/services/reporting.rs")).unwrap();

    for needle in [
        "impl RunServices",
        "pub enum ReportCheckOutcome",
        "pub struct GroupReportRequest",
        "pub fn finalize_group_report(",
    ] {
        assert!(
            !reporting.contains(needle),
            "src/run/services/reporting.rs should not own application-facing reporting flow `{needle}`"
        );
    }

    let application = fs::read_to_string(root.join("src/run/application/reporting.rs")).unwrap();
    for needle in [
        "pub enum ReportCheckOutcome",
        "pub struct GroupReportRequest",
        "pub fn finalize_group_report(",
    ] {
        assert!(
            application.contains(needle),
            "src/run/application/reporting.rs should own `{needle}`"
        );
    }
}

#[test]
fn authoring_commands_depend_on_application_boundary() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let commands_root = root.join("src/authoring/commands");
    let denylist = [
        "crate::authoring::authoring_workspace_dir",
        "crate::authoring::load_authoring_session",
        "crate::authoring::require_authoring_session",
        "crate::authoring::begin_authoring_session",
        "crate::authoring::validate::",
        "crate::authoring::workflow::",
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
                    "{} still bypasses src/authoring/application via `{needle}`",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "authoring commands must route through src/authoring/application:\n{}",
        hits.join("\n")
    );
}

#[test]
fn authoring_exposes_a_facade_instead_of_public_internal_modules() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let authoring_mod = read_repo_file(root, "src/authoring/mod.rs");
    assert_file_lacks_needles(
        &authoring_mod,
        "src/authoring/mod.rs should not publicly expose internal module",
        &["pub mod rules;", "pub mod validate;", "pub mod workflow;"],
    );
    assert_file_contains_needles(
        &authoring_mod,
        "src/authoring/mod.rs should expose the authoring facade via",
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
            "crate::authoring::workflow::",
            "crate::authoring::validate::",
            "crate::authoring::session::",
            "crate::authoring::rules::",
            "harness::authoring::workflow::",
        ],
        |path, needle| format!("{path} still depends on authoring internals via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "authoring callers should depend on the root facade instead of internal modules:\n{}",
        hits.join("\n")
    );
}
