use std::fs;
use std::process::Command;

use harness_hook::hook_adapters::adapter_for;
use harness_hook::hooks::protocol::context::NormalizedEvent;

#[test]
fn hook_agent_uses_the_canonical_protocol_identity() {
    let agent: harness_protocol::agent::HookAgent = harness_hook::hooks::HookAgent::Codex;
    assert_eq!(agent, harness_protocol::agent::HookAgent::Codex);
}

#[test]
fn standalone_adapter_parses_session_lifecycle_payload() {
    let context = adapter_for(harness_protocol::agent::HookAgent::Claude)
        .parse_input(
            br#"{"hook_event_name":"SessionStart","session_id":"runtime-1","cwd":"/tmp/project"}"#,
        )
        .expect("parse lifecycle payload");

    assert_eq!(context.event, NormalizedEvent::SessionStart);
    assert_eq!(context.session.session_id, "runtime-1");
}

#[test]
fn binary_exposes_the_hook_commands_without_the_root_cli() {
    let output = Command::new(env!("CARGO_BIN_EXE_harness-hook"))
        .arg("--help")
        .output()
        .expect("run harness-hook help");
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).expect("UTF-8 help");
    for command in [
        "tool-guard",
        "tool-result",
        "session-start",
        "session-stop",
        "prompt-submit",
        "pre-compact",
    ] {
        assert!(stdout.contains(command), "missing {command} in {stdout}");
    }
}

#[test]
fn standalone_package_has_no_root_harness_dependency() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let manifest =
        fs::read_to_string(format!("{manifest_dir}/Cargo.toml")).expect("read hook manifest");
    assert!(
        !manifest
            .lines()
            .any(|line| line.trim_start().starts_with("harness =")),
        "standalone hook must not depend on the root harness package"
    );
    for source in ["src/lib.rs", "src/main.rs"] {
        let contents = fs::read_to_string(format!("{manifest_dir}/{source}"))
            .unwrap_or_else(|error| panic!("read {source}: {error}"));
        assert!(
            !contents.contains("use harness::"),
            "{source} imports the root harness crate"
        );
    }
}
