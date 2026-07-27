use std::path::Path;

use super::helpers::collect_hits_in_paths;

/// #766/#779: `agents::service` owns session-lifecycle bookkeeping, not hook
/// payload framing, so it must not decide which adapter parses a raw payload
/// or reach into the adapter dispatch for an agent's display name. The CLI
/// command surface in `agents::transport` already carries the `HookAgent`
/// clap type for its `--agent` flag, so it is where the parse-then-call
/// decision belongs; `prompt_submit` now takes an already-normalized
/// `NormalizedHookContext` instead of raw bytes.
#[test]
fn agents_service_stays_off_the_hook_adapter_dispatch() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &["src/agents/service.rs"],
        &["adapter_for("],
        |path, needle| format!("{path} reaches into the hook adapter dispatch via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "agents::service should not decide how to parse a hook payload or resolve an agent's \
         adapter-owned name:\n{}",
        hits.join("\n")
    );
}
