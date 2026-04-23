use super::{manual_command_denial_reason, pre_tool_use_output, session_start_context};
use crate::hooks::adapters::HookAgent;

#[test]
fn session_start_context_mentions_mise_and_signing_requirements() {
    let context = session_start_context();
    assert!(context.contains("mise tasks ls"));
    assert!(context.contains("mise run <task>"));
    assert!(context.contains("Every commit uses `-sS`"));
    assert!(context.contains("1Password is unavailable"));
}

#[test]
fn denies_direct_version_script_with_task_replacement() {
    let reason = manual_command_denial_reason("./scripts/version.sh check")
        .expect("manual version script should be blocked");
    assert!(reason.contains("mise run version:check"));
}

#[test]
fn denies_raw_cargo_with_shared_wrapper_task() {
    let reason = manual_command_denial_reason("cargo test --lib cli::tests")
        .expect("raw cargo should be blocked");
    assert!(reason.contains("mise run cargo:local -- test --lib cli::tests"));
}

#[test]
fn denies_harness_setup_bootstrap_with_task_replacement() {
    let reason = manual_command_denial_reason("harness setup bootstrap --agents codex")
        .expect("raw setup bootstrap should be blocked");
    assert!(reason.contains("mise run setup:bootstrap -- --agents codex"));
}

#[test]
fn denies_harness_setup_agents_generate_check_with_existing_check_task() {
    let reason = manual_command_denial_reason("harness setup agents generate --check")
        .expect("raw setup agents generate --check should be blocked");
    assert!(reason.contains("mise run check:agent-assets"));
}

#[test]
fn denies_xcodebuild_with_task_passthrough() {
    let reason = manual_command_denial_reason(
        "xcodebuild -project apps/harness-monitor-macos/HarnessMonitor.xcodeproj build",
    )
    .expect("raw xcodebuild should be blocked");
    assert!(reason.contains(
        "mise run monitor:macos:xcodebuild -- -project apps/harness-monitor-macos/HarnessMonitor.xcodeproj build"
    ));
}

#[test]
fn denies_xcode_lock_wrapper_with_task_passthrough() {
    let reason = manual_command_denial_reason(
        "apps/harness-monitor-macos/Scripts/xcodebuild-with-lock.sh -scheme HarnessMonitor build",
    )
    .expect("xcodebuild wrapper should be blocked");
    assert!(reason.contains("mise run monitor:macos:xcodebuild -- -scheme HarnessMonitor build"));
}

#[test]
fn denies_quality_gate_script_with_task_replacement() {
    let reason =
        manual_command_denial_reason("apps/harness-monitor-macos/Scripts/run-quality-gates.sh")
            .expect("quality gate script should be blocked");
    assert!(reason.contains("mise run monitor:macos:lint"));
}

#[test]
fn denies_manual_observability_restart_chain() {
    let reason = manual_command_denial_reason(
        "./scripts/observability.sh stop && ./scripts/observability.sh start",
    )
    .expect("manual observability restart should be blocked");
    assert!(reason.contains("mise run observability:restart"));
}

#[test]
fn allows_existing_mise_commands() {
    assert!(manual_command_denial_reason("mise run check").is_none());
}

#[test]
fn renders_codex_pre_tool_use_denial_output() {
    let output = pre_tool_use_output(
        HookAgent::Codex,
        br#"{
            "hook_event_name":"PreToolUse",
            "tool_name":"Bash",
            "tool_input":{"command":"./scripts/version.sh check"}
        }"#,
    )
    .expect("hook output should render")
    .expect("manual command should be blocked");
    assert!(output.stdout.contains("\"decision\":\"block\""));
    assert!(output.stdout.contains("mise run version:check"));
}

#[test]
fn renders_claude_pre_tool_use_denial_output() {
    let output = pre_tool_use_output(
        HookAgent::Claude,
        br#"{
            "hook_event_name":"PreToolUse",
            "tool_name":"Bash",
            "tool_input":{"command":"cargo test --lib"}
        }"#,
    )
    .expect("hook output should render")
    .expect("manual command should be blocked");
    assert!(output.stdout.contains("\"hookEventName\":\"PreToolUse\""));
    assert!(output.stdout.contains("\"permissionDecision\":\"deny\""));
    assert!(output.stdout.contains("mise run cargo:local -- test --lib"));
}
