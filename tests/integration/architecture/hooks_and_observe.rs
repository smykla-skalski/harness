use std::path::Path;

use super::helpers::{
    assert_docs_contain_needles, assert_docs_lack_needles, assert_file_contains_needles,
    assert_file_lacks_needles, collect_hits_in_tree, read_repo_file,
};

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
    assert_file_lacks_needles(
        &maintenance,
        "src/observe/application/maintenance.rs should stay a facade instead of owning",
        &[
            "fn load_observer_state(",
            "fn execute_cycle(",
            "#[derive(Serialize)]",
        ],
    );
    assert_docs_contain_needles(
        &[
            &read_repo_file(root, "src/observe/application/maintenance/storage.rs"),
            &read_repo_file(root, "src/observe/application/maintenance/scan.rs"),
        ],
        "observe maintenance split modules should own",
        &["fn load_observer_state(", "fn execute_cycle("],
    );
}

#[test]
fn hooks_transport_does_not_hydrate_session_defaults() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = super::helpers::collect_hits_in_paths(
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
    assert_file_lacks_needles(
        &application,
        "src/hooks/application/context.rs should stay a facade instead of owning",
        &[
            "fn normalized_from_envelope(",
            "fn hydrate_normalized_context(",
            "fn hydrate_session(",
            "legacy_tool_context(",
        ],
    );
    assert!(
        root.join("src/hooks/application/context/hydration.rs")
            .exists(),
        "src/hooks/application/context/hydration.rs should exist after the context split"
    );
    assert!(
        root.join("src/hooks/application/context/interaction.rs")
            .exists(),
        "src/hooks/application/context/interaction.rs should exist after the context split"
    );

    let hydration = read_repo_file(root, "src/hooks/application/context/hydration.rs");
    assert_file_contains_needles(
        &hydration,
        "src/hooks/application/context/hydration.rs should own",
        &[
            "pub(crate) fn prepare_normalized_context(",
            "fn hydrate_normalized_context(",
            "fn hydrate_session(",
        ],
    );

    let interaction = read_repo_file(root, "src/hooks/application/context/interaction.rs");
    assert_file_contains_needles(
        &interaction,
        "src/hooks/application/context/interaction.rs should own",
        &["fn normalized_from_envelope(", "legacy_tool_context("],
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
fn hook_protocol_output_uses_typed_serialization() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let output = read_repo_file(root, "src/hooks/protocol/output.rs");

    assert_file_lacks_needles(
        &output,
        "src/hooks/protocol/output.rs should not hand-build JSON via",
        &["use serde_json::json;", "json!(", "payload[\""],
    );
    assert_file_contains_needles(
        &output,
        "src/hooks/protocol/output.rs should serialize typed hook DTOs via",
        &["#[derive(Serialize)]", "fn render_json<T: Serialize>("],
    );
}

fn assert_transport_outputs_avoid_manual_json(root: &Path) {
    for path in [
        "src/hooks/adapters/claude.rs",
        "src/hooks/adapters/gemini.rs",
        "src/hooks/adapters/codex.rs",
        "src/hooks/adapters/opencode/mod.rs",
        "src/observe/watch.rs",
        "src/observe/scan.rs",
        "src/observe/compare.rs",
        "src/observe/application/maintenance.rs",
        "src/setup/wrapper/mod.rs",
        "src/setup/wrapper/registrations.rs",
    ] {
        let contents = read_repo_file(root, path);
        assert_file_lacks_needles(
            &contents,
            &format!("{path} should not hand-build transport JSON via"),
            &["use serde_json::json;", "json!(", "serde_json::json!("],
        );
    }
}

fn assert_hook_adapters_use_typed_serialization(root: &Path) {
    let codex = read_repo_file(root, "src/hooks/adapters/codex.rs");
    assert_file_contains_needles(
        &codex,
        "src/hooks/adapters/codex.rs should use typed serialization helpers via",
        &[
            "#[derive(Serialize)]",
            "fn render_json<T: Serialize>(",
            "fn to_json_value<T: Serialize>(",
        ],
    );

    let opencode = read_repo_file(root, "src/hooks/adapters/opencode/mod.rs");
    assert_file_contains_needles(
        &opencode,
        "src/hooks/adapters/opencode/mod.rs should use typed serialization helpers via",
        &["#[derive(Serialize)]", "fn render_json<T: Serialize>("],
    );

    let claude = read_repo_file(root, "src/hooks/adapters/claude.rs");
    assert_file_contains_needles(
        &claude,
        "src/hooks/adapters/claude.rs should serialize typed hook registrations via",
        &["#[derive(Serialize)]", "struct ClaudeConfig"],
    );

    let gemini = read_repo_file(root, "src/hooks/adapters/gemini.rs");
    assert_file_contains_needles(
        &gemini,
        "src/hooks/adapters/gemini.rs should serialize typed hook payloads via",
        &[
            "#[derive(Serialize)]",
            "struct GeminiOutput",
            "fn render_json<T: Serialize>(",
        ],
    );
}

#[test]
fn codex_adapter_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let codex = read_repo_file(root, "src/hooks/adapters/codex.rs");
    assert_file_lacks_needles(
        &codex,
        "src/hooks/adapters/codex.rs should stay focused on production adapter logic instead of owning",
        &[
            "fn assert_notify_context(",
            "fn assert_notify_agent(",
            "fn parse_notify_payload_into_notification_context()",
            "mod tests {",
        ],
    );
    assert!(
        root.join("src/hooks/adapters/codex/tests.rs").exists(),
        "codex adapter split test module should exist"
    );
}

fn assert_observe_outputs_use_typed_serialization(root: &Path) {
    let maintenance_render = read_repo_file(root, "src/observe/application/maintenance/render.rs");
    assert_file_contains_needles(
        &maintenance_render,
        "src/observe/application/maintenance/render.rs should provide typed serialization helpers via",
        &[
            "use serde::Serialize;",
            "fn render_json<T: Serialize>(",
            "fn render_pretty_json<T: Serialize>(",
        ],
    );

    let maintenance_inspection =
        read_repo_file(root, "src/observe/application/maintenance/inspection.rs");
    let maintenance_status = read_repo_file(root, "src/observe/application/maintenance/status.rs");
    assert_docs_contain_needles(
        &[&maintenance_inspection, &maintenance_status],
        "observe maintenance split modules should render typed maintenance output via",
        &["#[derive(Serialize)]"],
    );

    let watch = read_repo_file(root, "src/observe/watch.rs");
    assert_file_contains_needles(
        &watch,
        "src/observe/watch.rs should emit typed watch status JSON via",
        &["#[derive(Serialize)]", "struct WatchStarted"],
    );

    let scan = read_repo_file(root, "src/observe/scan/execute.rs");
    assert_file_contains_needles(
        &scan,
        "src/observe/scan/execute.rs should emit typed scan status JSON via",
        &["#[derive(Serialize)]", "struct ScanStarted"],
    );

    let compare = read_repo_file(root, "src/observe/compare.rs");
    assert_file_contains_needles(
        &compare,
        "src/observe/compare.rs should render typed compare output via",
        &["#[derive(Serialize)]", "struct CompareResult"],
    );
}

fn assert_wrapper_outputs_use_typed_serialization(root: &Path) {
    let wrapper = read_repo_file(root, "src/setup/wrapper/registrations.rs");
    assert_file_contains_needles(
        &wrapper,
        "src/setup/wrapper/registrations.rs should serialize bridge bindings from typed structs via",
        &["#[derive(Serialize)]", "struct OpenCodeToolBindings"],
    );
}

#[test]
fn transport_outputs_use_typed_serialization_helpers() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert_transport_outputs_avoid_manual_json(root);
    assert_hook_adapters_use_typed_serialization(root);
    assert_observe_outputs_use_typed_serialization(root);
    assert_wrapper_outputs_use_typed_serialization(root);
}

#[test]
fn observe_scan_root_stays_prod_only() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let scan = read_repo_file(root, "src/observe/scan.rs");

    assert_file_lacks_needles(
        &scan,
        "src/observe/scan.rs should stay focused on facade exports instead of owning",
        &[
            "fn scan_with_limit(",
            "fn apply_category_filter(",
            "fn resolve_effective_bounds(",
            "fn render_scan_output(",
            "fn write_details_file(",
            "struct ScanStarted {",
        ],
    );

    for path in [
        "src/observe/scan/execute.rs",
        "src/observe/scan/filters.rs",
        "src/observe/scan/from.rs",
        "src/observe/scan/io.rs",
        "src/observe/scan/render.rs",
    ] {
        assert!(
            root.join(path).exists(),
            "observe scan split module should exist: {path}"
        );
    }
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
