use super::*;
use super::super::helpers::{read_repo_file, repo_path_exists};

#[test]
fn run_report_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let report = read_repo_file(root, "src/run/report.rs");

    for needle in [
        "pub enum Verdict",
        "pub enum GroupVerdict",
        "pub struct RunReportFrontmatter",
        "pub struct RunReport",
        "mod tests {",
    ] {
        assert!(
            !report.contains(needle),
            "src/run/report.rs should stay focused on report modeling and delegation instead of owning `{needle}`"
        );
    }

    for path in [
        "src/run/report/model.rs",
        "src/run/report/verdict.rs",
        "src/run/report/markdown.rs",
        "src/run/report/tests.rs",
    ] {
        assert!(
            repo_path_exists(root, path),
            "run report split module should exist: {path}"
        );
    }
}

#[test]
fn run_workflow_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let workflow = read_repo_file(root, "src/run/workflow/mod.rs");

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
        repo_path_exists(root, "src/run/workflow/tests.rs"),
        "run workflow split test module should exist"
    );
}

#[test]
fn run_task_output_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let task_output = read_repo_file(root, "src/run/services/task_output.rs");

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
        repo_path_exists(root, "src/run/services/task_output/tests.rs"),
        "run task_output split test module should exist"
    );
}

#[test]
fn run_prepared_suite_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let prepared_suite = read_repo_file(root, "src/run/prepared_suite/mod.rs");

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
        repo_path_exists(root, "src/run/prepared_suite/tests.rs"),
        "run prepared_suite split test module should exist"
    );
}

#[test]
fn run_validated_layout_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let validated = read_repo_file(root, "src/run/context/validated.rs");

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
        repo_path_exists(root, "src/run/context/validated/tests.rs"),
        "run validated-layout split test module should exist"
    );
}

#[test]
fn run_services_root_stays_a_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_services = read_repo_file(root, "src/run/services/mod.rs");

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
        repo_path_exists(root, "src/run/services/tests.rs"),
        "run services split test module should exist"
    );
}

#[test]
fn run_audit_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let run_audit = read_repo_file(root, "src/run/audit/mod.rs");

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
        repo_path_exists(root, "src/run/audit/tests.rs"),
        "run audit split test module should exist"
    );
}

#[test]
fn run_resolve_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let resolve_mod = read_repo_file(root, "src/run/resolve.rs");

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
        repo_path_exists(root, "src/run/resolve/tests.rs"),
        "run resolve split test module should exist"
    );
}

#[test]
fn run_state_capture_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let state_capture = read_repo_file(root, "src/run/state_capture.rs");

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
        repo_path_exists(root, "src/run/state_capture/tests.rs"),
        "run state_capture split test module should exist"
    );
}
