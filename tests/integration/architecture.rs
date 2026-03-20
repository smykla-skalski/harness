use std::fs;
use std::path::Path;

#[test]
fn new_domain_roots_exist() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "ARCHITECTURE.md",
        "src/app",
        "src/run",
        "src/authoring",
        "src/observe",
        "src/setup",
        "src/workspace",
        "src/kernel",
        "src/platform",
        "src/infra",
        "src/hooks",
    ] {
        assert!(root.join(path).exists(), "missing expected path: {path}");
    }
}

#[test]
fn legacy_scatter_roots_are_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    for path in [
        "src/commands",
        "src/workflow",
        "src/context",
        "src/run_services",
        "src/prepared_suite",
        "src/bootstrap.rs",
        "src/authoring_validate.rs",
        "src/cluster",
        "src/compose",
        "src/exec",
        "src/io",
        "src/runtime.rs",
        "src/compact",
        "src/core_defs",
        "src/schema",
        "src/rules",
        "src/shell_parse.rs",
        "src/platform/cluster",
    ] {
        assert!(
            !root.join(path).exists(),
            "legacy layout path should not exist anymore: {path}"
        );
    }
}

#[test]
fn cluster_topology_is_owned_by_kernel() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert!(
        root.join("src/kernel/topology.rs").exists(),
        "kernel topology module should exist"
    );

    let platform_mod = fs::read_to_string(root.join("src/platform/mod.rs")).unwrap();
    assert!(
        !platform_mod.contains("pub mod cluster;"),
        "src/platform/mod.rs should not publicly expose a cluster topology module"
    );

    let mut hits = Vec::new();
    for path in [
        "src/run/context/mod.rs",
        "src/run/context/aggregate.rs",
        "src/run/application/mod.rs",
        "src/run/application/preflight.rs",
        "src/run/application/inspection.rs",
        "src/run/application/capture.rs",
        "src/run/application/recording.rs",
        "src/setup/services/cluster.rs",
        "src/setup/capabilities.rs",
        "src/setup/cluster/kubernetes.rs",
        "src/setup/cluster/universal.rs",
        "src/platform/runtime.rs",
        "src/hooks/verify_bash.rs",
        "tests/integration/cluster.rs",
        "tests/integration/universal.rs",
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        if contents.contains("platform::cluster::") {
            hits.push(format!("{path} still depends on platform::cluster"));
        }
        if contents.contains("kernel::topology::") {
            continue;
        }
        hits.push(format!("{path} should depend on kernel::topology"));
    }

    assert!(
        hits.is_empty(),
        "generic cluster topology must be owned by kernel:\n{}",
        hits.join("\n")
    );
}

#[test]
fn platform_module_stays_internal_to_the_crate() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let lib_rs = fs::read_to_string(root.join("src/lib.rs")).unwrap();
    assert!(
        !lib_rs.contains("pub mod platform;"),
        "src/lib.rs should not expose platform as a public crate surface"
    );
    assert!(
        lib_rs.contains("pub(crate) mod platform;"),
        "src/lib.rs should keep platform crate-internal"
    );

    for path in [
        "tests/integration/universal.rs",
        "tests/integration/preflight.rs",
        "tests/integration/compact.rs",
        "tests/integration/commands/session_stop.rs",
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains("harness::platform::"),
            "{path} should not depend on the internal platform module"
        );
    }
}

#[test]
fn internal_code_uses_kernel_command_intent_instead_of_legacy_shell_parse() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let src_root = root.join("src");
    let mut stack = vec![src_root];
    let mut hits = Vec::new();

    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(&path).unwrap() {
            let entry = entry.unwrap();
            let child = entry.path();
            if child.is_dir() {
                stack.push(child);
                continue;
            }
            if !matches_extension(&child) {
                continue;
            }
            let contents = fs::read_to_string(&child).unwrap();
            if contents.contains("crate::shell_parse") {
                hits.push(format!(
                    "{} still references crate::shell_parse",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "found legacy command-intent imports:\n{}",
        hits.join("\n")
    );
}

#[test]
fn app_context_stays_app_wiring_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let contents = fs::read_to_string(root.join("src/app/command_context.rs")).unwrap();

    for needle in [
        "RunAggregate",
        "RunContext",
        "RunRepository",
        "resolve_run_directory",
        "RunDirArgs",
        "BlockRegistry",
        "shared_blocks(",
        "blocks(",
    ] {
        assert!(
            !contents.contains(needle),
            "src/app/command_context.rs should not own run resolution via `{needle}`"
        );
    }
}

#[test]
fn bespoke_frontmatter_paths_are_gone() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let denylist = ["extract_raw_frontmatter(", "serde_yml::Mapping"];
    let hits = collect_hits_in_tree(&root.join("src"), root, None, &denylist, |path, needle| {
        format!("{path} contains forbidden bespoke frontmatter logic `{needle}`")
    });

    assert!(
        hits.is_empty(),
        "found bespoke frontmatter logic after dependency migration:\n{}",
        hits.join("\n")
    );
}

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
        if !matches_extension(&child) {
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
            if !matches_extension(&child) {
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
        if !matches_extension(&child) {
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

#[test]
fn application_submodules_are_not_public_library_surface() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needle) in [
        ("src/run/mod.rs", "pub mod application;"),
        ("src/authoring/mod.rs", "pub mod application;"),
        ("src/hooks/mod.rs", "pub mod application;"),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains(needle),
            "{path} should keep `application` crate-internal instead of exporting `{needle}`"
        );
        assert!(
            contents.contains("pub(crate) mod application;"),
            "{path} should expose `application` as crate-internal only"
        );
    }

    let hooks_root = fs::read_to_string(root.join("src/hooks/mod.rs")).unwrap();
    assert!(
        hooks_root.contains("pub use self::application::GuardContext;"),
        "src/hooks/mod.rs should re-export GuardContext as the stable public hook facade"
    );

    let testkit_builders = fs::read_to_string(root.join("testkit/src/builders.rs")).unwrap();
    assert!(
        !testkit_builders.contains("harness::hooks::application::GuardContext"),
        "testkit should not depend on the private hooks::application module"
    );
    assert!(
        testkit_builders.contains("harness::hooks::GuardContext"),
        "testkit should depend on the public hooks facade for GuardContext"
    );
}

#[test]
fn transport_command_modules_stay_internal_to_domains() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, needle) in [
        ("src/run/mod.rs", "pub mod commands;"),
        ("src/authoring/mod.rs", "pub mod commands;"),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains(needle),
            "{path} should keep `commands` crate-internal instead of exporting `{needle}`"
        );
        assert!(
            contents.contains("pub(crate) mod commands;"),
            "{path} should expose `commands` as crate-internal only"
        );
    }

    for path in [
        "src/app/cli.rs",
        "tests/integration/helpers.rs",
        "tests/integration/cluster.rs",
        "tests/integration/commands/api.rs",
        "tests/integration/commands/init_run.rs",
        "tests/integration/commands/record.rs",
        "tests/integration/commands/report.rs",
        "tests/integration/commands/runner_state.rs",
        "tests/integration/commands/service.rs",
        "tests/integration/preflight.rs",
        "tests/integration/universal.rs",
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains("::commands::"),
            "{path} should depend on domain-root transport exports instead of `::commands::`"
        );
    }
}

#[test]
fn helper_modules_do_not_leak_publicly() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    for (path, public_needle, crate_needle) in [
        (
            "src/app/mod.rs",
            "pub mod command_context;",
            "pub(crate) mod command_context;",
        ),
        (
            "src/setup/mod.rs",
            "pub mod wrapper;",
            "pub(crate) mod wrapper;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod classifier;",
            "pub(crate) mod classifier;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod patterns;",
            "pub(crate) mod patterns;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod session;",
            "pub(crate) mod session;",
        ),
        (
            "src/observe/mod.rs",
            "pub mod types;",
            "pub(crate) mod types;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod debug;",
            "pub(crate) mod debug;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod runner_policy;",
            "pub(crate) mod runner_policy;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod session;",
            "pub(crate) mod session;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod adapters;",
            "pub(crate) mod adapters;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod guards;",
            "pub(crate) mod guards;",
        ),
        (
            "src/hooks/mod.rs",
            "pub mod registry;",
            "pub(crate) mod registry;",
        ),
    ] {
        let contents = fs::read_to_string(root.join(path)).unwrap();
        assert!(
            !contents.contains(public_needle),
            "{path} should not leak helper module `{public_needle}` publicly"
        );
        assert!(
            contents.contains(crate_needle),
            "{path} should keep helper module `{crate_needle}` crate-internal"
        );
    }

    let setup_session = fs::read_to_string(root.join("src/setup/session.rs")).unwrap();
    assert!(
        !setup_session.contains("crate::hooks::session::SessionStartHookOutput"),
        "src/setup/session.rs should not depend on the private hooks::session module"
    );
    assert!(
        setup_session.contains("crate::hooks::SessionStartHookOutput"),
        "src/setup/session.rs should use the public hooks facade for SessionStartHookOutput"
    );

    let hooks_root = fs::read_to_string(root.join("src/hooks/mod.rs")).unwrap();
    assert!(
        hooks_root.contains(
            "pub use self::session::{PreCompactHookInput, SessionStartHookInput, SessionStartHookOutput};"
        ),
        "src/hooks/mod.rs should re-export session hook payload types through the hooks facade"
    );
}

#[test]
fn observe_transport_stays_transport_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let transport = read_repo_file(root, "src/observe/mod.rs");
    assert_file_lacks_needles(
        &transport,
        "src/observe/mod.rs should stay transport-only instead of owning",
        &[
            "pub fn execute(",
            "fn execute_scan_mode(",
            "fn execute_dump_mode(",
            "fn resolve_scan_action(",
            "fn state_file_path(",
            "fn load_observer_state(",
            "fn save_observer_state(",
            "fn execute_cycle(",
            "fn execute_status(",
            "fn execute_resume(",
            "fn execute_verify(",
            "fn execute_resolve_start(",
            "fn execute_mute(",
            "fn execute_unmute(",
        ],
    );

    let application = read_repo_file(root, "src/observe/application/mod.rs");
    assert_file_contains_needles(
        &application,
        "src/observe/application/mod.rs should own",
        &["pub(crate) fn execute(", "pub(crate) enum ObserveRequest"],
    );
    assert_file_lacks_needles(
        &application,
        "src/observe/application/mod.rs should not depend on transport enum",
        &["ObserveMode", "ObserveScanActionKind"],
    );

    let maintenance = read_repo_file(root, "src/observe/application/maintenance.rs");
    assert_file_contains_needles(
        &maintenance,
        "src/observe/application/maintenance.rs should own",
        &["fn load_observer_state(", "fn execute_cycle("],
    );
}

#[test]
fn hooks_transport_does_not_hydrate_session_defaults() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &[
            "src/hooks/protocol/context.rs",
            "src/hooks/adapters/mod.rs",
            "src/hooks/adapters/codex.rs",
        ],
        &["current_dir("],
        |path, _| format!("{path} should not hydrate ambient cwd defaults in hooks transport"),
    );
    assert!(hits.is_empty(), "{}", hits.join("\n"));

    let protocol = read_repo_file(root, "src/hooks/protocol/context.rs");
    assert!(
        protocol.contains("pub cwd: Option<PathBuf>"),
        "src/hooks/protocol/context.rs should preserve missing cwd in normalized transport context"
    );
    assert_file_lacks_needles(
        &protocol,
        "src/hooks/protocol/context.rs should stay transport-only instead of owning",
        &[
            "HookEnvelopePayload",
            "legacy_tool_context",
            "fn normalized_from_envelope(",
            "fn with_skill(",
            "fn with_default_event(",
        ],
    );

    let application = read_repo_file(root, "src/hooks/application/context.rs");
    assert_file_contains_needles(
        &application,
        "src/hooks/application/context.rs should own",
        &[
            "fn normalized_from_envelope(",
            "pub(crate) fn prepare_normalized_context(",
            "fn hydrate_normalized_context(",
            "fn hydrate_session(",
            "legacy_tool_context(",
        ],
    );
}

#[test]
fn setup_does_not_mutate_run_repository_directly() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("src/setup"),
        root,
        None,
        &[
            "RunRepository",
            "current_pointer_path(",
            "RunLayout::current_pointer",
            "write_json_pretty(",
        ],
        |path, needle| format!("{path} still reaches into run-owned persistence via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "setup should go through run application helpers for current-run persistence:\n{}",
        hits.join("\n")
    );
}

#[test]
fn setup_session_transport_stays_transport_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let session_mod = read_repo_file(root, "src/setup/session.rs");
    assert_file_lacks_needles(
        &session_mod,
        "src/setup/session.rs should stay transport-only instead of owning",
        &[
            "wrapper::main(",
            "pending_compact_handoff(",
            "render_hydration_context(",
            "consume_compact_handoff(",
            "ephemeral_metallb::cleanup_templates(",
            "RunApplication::current_run_dir(",
            "RunApplication::clear_current_pointer(",
        ],
    );

    let service = read_repo_file(root, "src/setup/services/session.rs");
    assert_file_contains_needles(
        &service,
        "src/setup/services/session.rs should own",
        &[
            "fn bootstrap_project_wrapper(",
            "fn restore_compact_handoff(",
            "fn cleanup_current_run_context(",
        ],
    );
}

#[test]
fn setup_wrapper_does_not_depend_on_block_registry() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let contents = read_repo_file(root, "src/setup/wrapper.rs");
    assert!(
        !contents.contains("BlockRegistry"),
        "src/setup/wrapper.rs should use pure runner policy data instead of BlockRegistry"
    );
}

#[test]
fn infra_blocks_do_not_export_legacy_block_registry() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let blocks_mod = read_repo_file(root, "src/infra/blocks/mod.rs");
    let registry = read_repo_file(root, "src/infra/blocks/registry.rs");

    assert!(
        !blocks_mod.contains("BlockRegistry"),
        "src/infra/blocks/mod.rs should not export the retired BlockRegistry"
    );
    assert!(
        !registry.contains("pub struct BlockRegistry"),
        "src/infra/blocks/registry.rs should keep only block requirement policy, not a global registry"
    );
}

#[test]
fn tool_fact_model_is_owned_by_kernel() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hooks_context = read_repo_file(root, "src/hooks/protocol/context.rs");
    assert_file_lacks_needles(
        &hooks_context,
        "src/hooks/protocol/context.rs should consume kernel::tooling instead of redefining",
        &[
            "pub enum ToolCategory",
            "pub enum ToolInput",
            "pub struct ToolContext",
            "fn normalize_tool_input",
        ],
    );

    let kernel_tooling = read_repo_file(root, "src/kernel/tooling.rs");
    assert!(
        kernel_tooling.contains("pub struct ToolContext"),
        "src/kernel/tooling.rs should own the shared tool fact model"
    );
}

#[test]
fn hook_application_owns_guard_context_hydration() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let protocol_context = read_repo_file(root, "src/hooks/protocol/context.rs");
    assert_file_lacks_needles(
        &protocol_context,
        "src/hooks/protocol/context.rs should stay transport-only instead of owning",
        &[
            "pub struct GuardContext",
            "RunContext",
            "RunnerWorkflowState",
            "AuthorWorkflowState",
            "load_run_context",
            "load_runner_state",
            "load_author_state",
        ],
    );

    let application_context = read_repo_file(root, "src/hooks/application/context.rs");
    assert!(
        application_context.contains("pub struct GuardContext"),
        "src/hooks/application/context.rs should own the hook policy input context"
    );

    let hits = collect_hits_in_tree(
        &root.join("src/hooks"),
        root,
        None,
        &["protocol::context::GuardContext"],
        |path, _| format!("{path} still imports GuardContext from hooks::protocol"),
    );

    assert!(
        hits.is_empty(),
        "hook code should consume hooks::application::GuardContext instead of the protocol layer:\n{}",
        hits.join("\n")
    );
}

#[test]
fn kuma_contracts_are_isolated_to_block_namespace() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("src"),
        root,
        Some(&root.join("src/infra/blocks/kuma")),
        &[
            "Kuma test harness",
            "~kuma",
            ".join(\"kuma\")",
            "`harness cluster`",
            "harness cluster ",
            "`harness token`",
            "harness token ",
            "`harness service`",
            "harness service ",
            "`harness api`",
            "harness api ",
            "`harness kumactl`",
            "harness kumactl ",
        ],
        |path, needle| format!("{path} contains forbidden Kuma contract `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "found Kuma contract leaks outside src/infra/blocks/kuma:\n{}",
        hits.join("\n")
    );
}

#[test]
fn docs_do_not_reference_legacy_kuma_storage_paths() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let readme = read_repo_file(root, "README.md");
    assert_file_lacks_needles(
        &readme,
        "README.md should not reference legacy Kuma storage paths via",
        &["$XDG_DATA_HOME/kuma", ".local/share/kuma"],
    );
}

#[test]
fn observe_skill_matches_current_cli_surface() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let docs = [
        read_repo_file(root, ".claude/skills/observe/SKILL.md"),
        read_repo_file(root, ".claude/skills/observe/references/overrides.md"),
        read_repo_file(root, ".claude/skills/observe/references/command-surface.md"),
    ];
    let all_docs: Vec<&str> = docs.iter().map(String::as_str).collect();

    assert_docs_lack_needles(
        &all_docs,
        "observe skill docs should not use legacy observe contract",
        &[
            "harness observe cycle",
            "harness observe status",
            "harness observe resume",
            "harness observe compare",
            "harness observe doctor",
            "$XDG_DATA_HOME/kuma/observe",
        ],
    );
    assert_docs_contain_needles(
        &all_docs,
        "observe skill docs should describe current observe contract via",
        &[
            "harness observe scan <session-id> --action cycle",
            "harness observe scan <session-id> --action status",
            "$XDG_DATA_HOME/harness/observe/<SESSION_ID>.state",
        ],
    );
}

fn assert_file_lacks_needles(contents: &str, message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(!contents.contains(needle), "{message_prefix} `{needle}`");
    }
}

fn assert_file_contains_needles(contents: &str, message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(contents.contains(needle), "{message_prefix} `{needle}`");
    }
}

fn assert_docs_lack_needles(docs: &[&str], message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            !docs.iter().any(|doc| doc.contains(needle)),
            "{message_prefix} `{needle}`"
        );
    }
}

fn assert_docs_contain_needles(docs: &[&str], message_prefix: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            docs.iter().any(|doc| doc.contains(needle)),
            "{message_prefix} `{needle}`"
        );
    }
}

fn read_repo_file(root: &Path, path: &str) -> String {
    fs::read_to_string(root.join(path)).unwrap()
}

fn collect_hits_in_paths<F>(root: &Path, paths: &[&str], needles: &[&str], render: F) -> Vec<String>
where
    F: Fn(&str, &str) -> String,
{
    let mut hits = Vec::new();
    for path in paths {
        let contents = read_repo_file(root, path);
        for needle in needles {
            if contents.contains(needle) {
                hits.push(render(path, needle));
            }
        }
    }
    hits
}

fn collect_hits_in_tree<F>(
    start: &Path,
    root: &Path,
    skip_prefix: Option<&Path>,
    needles: &[&str],
    render: F,
) -> Vec<String>
where
    F: Fn(&str, &str) -> String,
{
    let mut hits = Vec::new();

    for entry in walkdir::WalkDir::new(start)
        .into_iter()
        .filter_map(Result::ok)
    {
        let child = entry.into_path();
        if skip_prefix.is_some_and(|prefix| child.starts_with(prefix)) || child.is_dir() {
            continue;
        }
        if !matches_extension(&child) {
            continue;
        }
        let contents = fs::read_to_string(&child).unwrap();
        let relative = child.strip_prefix(root).unwrap().display().to_string();
        for needle in needles {
            if contents.contains(needle) {
                hits.push(render(&relative, needle));
            }
        }
    }

    hits
}

fn matches_extension(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("rs" | "snap" | "md")
    )
}
