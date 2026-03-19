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
    ] {
        assert!(
            !root.join(path).exists(),
            "legacy layout path should not exist anymore: {path}"
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
    let mut stack = vec![root.join("src")];
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
            for needle in denylist {
                if contents.contains(needle) {
                    hits.push(format!(
                        "{} contains forbidden bespoke frontmatter logic `{needle}`",
                        child.strip_prefix(root).unwrap().display()
                    ));
                }
            }
        }
    }

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

    for needle in ["pub fn from_run_dir(", "pub fn from_current("] {
        assert!(
            !contents.contains(needle),
            "src/run/services/mod.rs should not own persistence/session loading via `{needle}`"
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
fn observe_transport_stays_transport_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let transport = fs::read_to_string(root.join("src/observe/mod.rs")).unwrap();

    for needle in [
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
    ] {
        assert!(
            !transport.contains(needle),
            "src/observe/mod.rs should stay transport-only instead of owning `{needle}`"
        );
    }

    let application = fs::read_to_string(root.join("src/observe/application/mod.rs")).unwrap();
    assert!(
        application.contains("pub(crate) fn execute("),
        "src/observe/application/mod.rs should own observe execution dispatch"
    );

    let maintenance =
        fs::read_to_string(root.join("src/observe/application/maintenance.rs")).unwrap();
    for needle in ["fn load_observer_state(", "fn execute_cycle("] {
        assert!(
            maintenance.contains(needle),
            "src/observe/application/maintenance.rs should own `{needle}`"
        );
    }
}

#[test]
fn setup_does_not_mutate_run_repository_directly() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let setup_root = root.join("src/setup");
    let denylist = [
        "RunRepository",
        "current_pointer_path(",
        "RunLayout::current_pointer",
        "write_json_pretty(",
    ];
    let mut stack = vec![setup_root];
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
            for needle in denylist {
                if contents.contains(needle) {
                    hits.push(format!(
                        "{} still reaches into run-owned persistence via `{needle}`",
                        child.strip_prefix(root).unwrap().display()
                    ));
                }
            }
        }
    }

    assert!(
        hits.is_empty(),
        "setup should go through run application helpers for current-run persistence:\n{}",
        hits.join("\n")
    );
}

#[test]
fn setup_wrapper_does_not_depend_on_block_registry() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let contents = fs::read_to_string(root.join("src/setup/wrapper.rs")).unwrap();
    assert!(
        !contents.contains("BlockRegistry"),
        "src/setup/wrapper.rs should use pure runner policy data instead of BlockRegistry"
    );
}

#[test]
fn tool_fact_model_is_owned_by_kernel() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hooks_context = fs::read_to_string(root.join("src/hooks/protocol/context.rs")).unwrap();

    for needle in [
        "pub enum ToolCategory",
        "pub enum ToolInput",
        "pub struct ToolContext",
        "fn normalize_tool_input",
    ] {
        assert!(
            !hooks_context.contains(needle),
            "src/hooks/protocol/context.rs should consume kernel::tooling instead of redefining `{needle}`"
        );
    }

    let kernel_tooling = fs::read_to_string(root.join("src/kernel/tooling.rs")).unwrap();
    assert!(
        kernel_tooling.contains("pub struct ToolContext"),
        "src/kernel/tooling.rs should own the shared tool fact model"
    );
}

#[test]
fn hook_application_owns_guard_context_hydration() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let protocol_context = fs::read_to_string(root.join("src/hooks/protocol/context.rs")).unwrap();

    for needle in [
        "pub struct GuardContext",
        "RunContext",
        "RunnerWorkflowState",
        "AuthorWorkflowState",
        "load_run_context",
        "load_runner_state",
        "load_author_state",
    ] {
        assert!(
            !protocol_context.contains(needle),
            "src/hooks/protocol/context.rs should stay transport-only instead of owning `{needle}`"
        );
    }

    let application_context =
        fs::read_to_string(root.join("src/hooks/application/context.rs")).unwrap();
    assert!(
        application_context.contains("pub struct GuardContext"),
        "src/hooks/application/context.rs should own the hook policy input context"
    );

    let hooks_root = root.join("src/hooks");
    let mut stack = vec![hooks_root];
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
            if contents.contains("protocol::context::GuardContext") {
                hits.push(format!(
                    "{} still imports GuardContext from hooks::protocol",
                    child.strip_prefix(root).unwrap().display()
                ));
            }
        }
    }

    assert!(
        hits.is_empty(),
        "hook code should consume hooks::application::GuardContext instead of the protocol layer:\n{}",
        hits.join("\n")
    );
}

#[test]
fn kuma_contracts_are_isolated_to_block_namespace() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let src_root = root.join("src");
    let excluded = root.join("src/infra/blocks/kuma");
    let denylist = [
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
    ];

    let mut stack = vec![src_root];
    let mut hits = Vec::new();

    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(&path).unwrap() {
            let entry = entry.unwrap();
            let child = entry.path();
            if child.starts_with(&excluded) {
                continue;
            }
            if child.is_dir() {
                stack.push(child);
                continue;
            }
            if !matches_extension(&child) {
                continue;
            }
            let contents = fs::read_to_string(&child).unwrap();
            for needle in denylist {
                if contents.contains(needle) {
                    hits.push(format!(
                        "{} contains forbidden Kuma contract `{needle}`",
                        child.strip_prefix(root).unwrap().display()
                    ));
                }
            }
        }
    }

    assert!(
        hits.is_empty(),
        "found Kuma contract leaks outside src/infra/blocks/kuma:\n{}",
        hits.join("\n")
    );
}

fn matches_extension(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()),
        Some("rs" | "snap" | "md")
    )
}
