use assert_cmd::Command;
use predicates::str::contains;

use aff::hook_agent::HookAgent;
use aff::repo_policy::{manual_command_denial_reason, pre_tool_use_output, session_start_context};

#[test]
fn session_start_context_mentions_mise_and_signing_requirements() {
    let context = session_start_context();
    assert!(context.contains("mise tasks ls"));
    assert!(context.contains("mise run <task>"));
    assert!(context.contains("Every commit uses `-sS`"));
}

#[test]
fn session_start_context_requires_council_before_commit() {
    let context = session_start_context();
    assert!(context.contains("/council"));
    assert!(context.contains("Before every commit"));
}

#[test]
fn denies_raw_cargo_with_task_replacement() {
    let reason = manual_command_denial_reason("cargo test --lib cli::tests")
        .expect("command should parse")
        .expect("raw cargo should be blocked");
    assert!(reason.contains("mise run cargo:local -- test --lib cli::tests"));
}

#[test]
fn denies_harness_setup_bootstrap_with_task_replacement() {
    let reason = manual_command_denial_reason("harness setup bootstrap --agents codex")
        .expect("command should parse")
        .expect("raw setup bootstrap should be blocked");
    assert!(reason.contains("mise run setup:bootstrap -- --agents codex"));
}

#[test]
fn denies_shell_wrapped_command_and_preserves_env_prefix() {
    let reason = manual_command_denial_reason(
        "rtk env XCODE_ONLY_TESTING=HarnessMonitorKitTests/SupervisorServiceTests bash -lc 'mise run monitor:macos:test'",
    )
    .expect("command should parse")
    .expect("shell-wrapped mise command should be blocked");
    assert!(reason.contains("XCODE_ONLY_TESTING="));
    assert!(reason.contains("mise run monitor:macos:test"));
}

#[test]
fn allows_existing_mise_commands() {
    assert!(
        manual_command_denial_reason("mise run check")
            .expect("command should parse")
            .is_none()
    );
}

#[test]
fn allows_quoted_urls_with_ampersands() {
    assert!(
        manual_command_denial_reason("curl 'https://example.com?a=1&b=2'")
            .expect("command should parse")
            .is_none()
    );
}

#[test]
fn rejects_unparseable_command_text() {
    let error = pre_tool_use_output(
        HookAgent::Codex,
        br#"{
            "hook_event_name":"PreToolUse",
            "tool_name":"Bash",
            "tool_input":{"command":"cargo 'unterminated"}
        }"#,
    )
    .expect_err("unparseable command text should fail closed");
    assert!(error.contains("failed to parse command text"));
}

#[test]
fn rejects_unsupported_shell_wrapped_shape() {
    let error =
        manual_command_denial_reason("bash -lc 'mise run check&&mise run test -- test:unit'")
            .expect_err("unsupported shell wrapper shape should fail");
    assert!(error.contains("unsupported wrapped shell command shape"));
}

#[test]
fn rejects_unsupported_top_level_shell_shape() {
    let error = manual_command_denial_reason("cargo test&&cargo check")
        .expect_err("unsupported top-level shell shape should fail");
    assert!(error.contains("unsupported top-level command shape"));
}

#[test]
fn restart_chain_shortcut_is_exact_contract() {
    let exact = manual_command_denial_reason(
        "./scripts/observability.sh stop && ./scripts/observability.sh start",
    )
    .expect("command should parse")
    .expect("exact restart chain should be blocked");
    assert!(exact.contains("mise run observability:restart"));

    let non_exact = manual_command_denial_reason(
        "./scripts/observability.sh stop ; ./scripts/observability.sh start",
    )
    .expect("command should parse")
    .expect("non-exact chain should still be blocked");
    assert!(!non_exact.contains("observability:restart"));
    assert!(non_exact.contains("mise run observability:stop"));
    assert!(non_exact.contains("mise run observability:start"));
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
    .expect("manual command should be blocked");
    assert!(output.stdout.contains("\"decision\":\"block\""));
    assert!(output.stdout.contains("mise run version:check"));
}

#[test]
fn renders_copilot_pre_tool_use_denial_output() {
    let output = pre_tool_use_output(
        HookAgent::Copilot,
        br#"{
            "toolName":"bash",
            "toolArgs":"{\"command\":\"./scripts/version.sh check\"}"
        }"#,
    )
    .expect("manual command should be blocked");
    assert!(output.stdout.contains("\"permissionDecision\":\"deny\""));
    assert!(output.stdout.contains("mise run version:check"));
}

#[test]
fn rejects_malformed_hook_payloads() {
    let error = pre_tool_use_output(HookAgent::Codex, br#"{"hook_event_name":"PreToolUse""#)
        .expect_err("malformed payload should fail");
    assert!(error.contains("invalid hook payload"));
}

#[test]
fn rejects_malformed_copilot_tool_args() {
    let error = pre_tool_use_output(
        HookAgent::Copilot,
        br#"{
            "toolName":"bash",
            "toolArgs":"{\"command\":\"./scripts/version.sh check\""
        }"#,
    )
    .expect_err("malformed copilot toolArgs should fail");
    assert!(error.contains("invalid hook payload"));
    assert!(error.contains("toolArgs"));
}

#[test]
fn rejects_unsupported_hook_events() {
    let error = pre_tool_use_output(
        HookAgent::Codex,
        br#"{
            "hook_event_name":"SessionStart",
            "tool_name":"Bash",
            "tool_input":{"command":"./scripts/version.sh check"}
        }"#,
    )
    .expect_err("unsupported events should fail");
    assert!(error.contains("unsupported hook event"));
}

#[test]
fn session_start_cli_emits_hook_output_json() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["session-start", "--agent", "codex"])
        .assert()
        .success()
        .stdout(contains("\"hookEventName\":\"SessionStart\""))
        .stdout(contains("mise tasks ls"));
}

#[test]
fn repo_policy_cli_blocks_manual_commands() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["repo-policy", "--agent", "codex"])
        .write_stdin(
            br#"{
                "hook_event_name":"PreToolUse",
                "tool_name":"Bash",
                "tool_input":{"command":"./scripts/version.sh check"}
            }"#,
        )
        .assert()
        .success()
        .stdout(contains("mise run version:check"));
}

#[test]
fn repo_policy_cli_reports_malformed_payloads_on_stderr() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["repo-policy", "--agent", "codex"])
        .write_stdin(br#"{"hook_event_name":"PreToolUse""#)
        .assert()
        .failure()
        .stdout("")
        .stderr(contains("invalid hook payload"));
}

#[test]
fn repo_policy_cli_reports_unparseable_command_text_on_stderr() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["repo-policy", "--agent", "codex"])
        .write_stdin(
            br#"{
                "hook_event_name":"PreToolUse",
                "tool_name":"Bash",
                "tool_input":{"command":"cargo 'unterminated"}
            }"#,
        )
        .assert()
        .failure()
        .stdout("")
        .stderr(contains("failed to parse command text"));
}

#[test]
fn repo_policy_cli_reports_unsupported_top_level_shape_on_stderr() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["repo-policy", "--agent", "codex"])
        .write_stdin(
            br#"{
                "hook_event_name":"PreToolUse",
                "tool_name":"Bash",
                "tool_input":{"command":"cargo test&&cargo check"}
            }"#,
        )
        .assert()
        .failure()
        .stdout("")
        .stderr(contains("unsupported top-level command shape"));
}

#[test]
fn repo_policy_cli_reports_malformed_copilot_tool_args_on_stderr() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["repo-policy", "--agent", "copilot"])
        .write_stdin(
            br#"{
                "toolName":"bash",
                "toolArgs":"{\"command\":\"./scripts/version.sh check\""
            }"#,
        )
        .assert()
        .failure()
        .stdout("")
        .stderr(contains("invalid hook payload"))
        .stderr(contains("toolArgs"));
}

#[test]
fn repo_policy_cli_reports_unsupported_events_on_stderr() {
    Command::cargo_bin("aff")
        .expect("aff binary")
        .args(["repo-policy", "--agent", "codex"])
        .write_stdin(
            br#"{
                "hook_event_name":"SessionStart",
                "tool_name":"Bash",
                "tool_input":{"command":"./scripts/version.sh check"}
            }"#,
        )
        .assert()
        .failure()
        .stdout("")
        .stderr(contains("unsupported hook event"));
}
