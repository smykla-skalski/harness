use std::path::Path;

use fs_err as fs;

use super::super::registrations::{build_codex_config, lifecycle_command};
use super::super::write_agent_bootstrap;
use crate::hooks::adapters::HookAgent;

#[test]
fn lifecycle_commands_include_project_dirs() {
    assert_eq!(
        lifecycle_command(HookAgent::Claude, "session-start"),
        "harness agents session-start --agent claude --project-dir \"$CLAUDE_PROJECT_DIR\""
    );
    assert_eq!(
        lifecycle_command(HookAgent::Gemini, "pre-compact"),
        "harness pre-compact --project-dir \"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}\""
    );
    assert_eq!(
        lifecycle_command(HookAgent::Codex, "session-stop"),
        "harness agents session-stop --agent codex --project-dir \"$PWD\""
    );
    assert_eq!(
        lifecycle_command(HookAgent::Copilot, "prompt-submit"),
        "harness agents prompt-submit --agent copilot --project-dir \"$PWD\""
    );
}

#[test]
fn claude_lifecycle_commands_match_hook_template() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hook_template =
        fs::read_to_string(root.join(".claude/plugins/suite/hooks/hooks.json")).unwrap();
    let hooks: serde_json::Value = serde_json::from_str(&hook_template).unwrap();

    let commands = [
        (
            "PreCompact",
            lifecycle_command(HookAgent::Claude, "pre-compact"),
        ),
        (
            "SessionStart",
            lifecycle_command(HookAgent::Claude, "session-start"),
        ),
        ("Stop", lifecycle_command(HookAgent::Claude, "session-stop")),
    ];

    for (event, expected) in commands {
        let actual = hooks["hooks"][event][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        let normalized_actual = actual.replace("${CLAUDE_PLUGIN_ROOT}/", "");
        assert_eq!(
            normalized_actual, expected,
            "{event} lifecycle command drifted"
        );
    }
}

#[test]
fn build_codex_config_includes_notify_and_hooks_flag() {
    let config = build_codex_config();
    assert!(config.contains("\"audit-turn\""));
    assert!(config.contains("codex_hooks = true"));
    assert!(config.contains("[hooks]"));
    assert!(config.contains(
        "session_start = [\"harness\", \"agents\", \"session-start\", \"--agent\", \"codex\"]"
    ));
    assert!(config.contains("pre_compact = [\"harness\", \"pre-compact\"]"));
    assert!(config.contains(
        "session_end = [\"harness\", \"agents\", \"session-stop\", \"--agent\", \"codex\"]"
    ));
}

fn assert_codex_hooks(hooks: &str) {
    assert!(hooks.contains("\"Stop\""));
    assert!(hooks.contains("\"UserPromptSubmit\""));
    assert!(hooks.contains("\"PreToolUse\""));
    assert!(hooks.contains("\"PostToolUse\""));
    assert!(hooks.contains("\"SubagentStart\""));
    assert!(hooks.contains("\"SubagentStop\""));
    assert!(hooks.contains("tool-guard"));
    assert!(hooks.contains("tool-result"));
}

#[test]
fn write_agent_bootstrap_writes_codex_notify_config() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Codex).unwrap();

    let session_start_skill = dir
        .path()
        .join(".agents")
        .join("skills")
        .join("harness-session-start")
        .join("SKILL.md");
    let plugin_skill = dir
        .path()
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("start")
        .join("SKILL.md");
    let hooks_path = dir.path().join(".codex").join("hooks.json");
    let config_path = dir.path().join(".codex").join("config.toml");

    assert!(written.contains(&session_start_skill));
    assert!(written.contains(&plugin_skill));
    assert!(written.contains(&hooks_path));
    assert!(written.contains(&config_path));

    let skill = fs::read_to_string(session_start_skill).unwrap();
    assert!(skill.contains("name: harness:session:start"));
    let plugin_skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(plugin_skill.contains("name: session:start"));
    assert_codex_hooks(&fs::read_to_string(hooks_path).unwrap());
    let config = fs::read_to_string(config_path).unwrap();
    assert!(config.contains("\"audit-turn\""));
    assert!(config.contains("codex_hooks = true"));
    assert!(config.contains("[hooks]"));
}

#[test]
fn write_agent_bootstrap_writes_claude_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Claude).unwrap();

    let settings_path = dir.path().join(".claude").join("settings.json");
    let plugin_skill = dir
        .path()
        .join(".claude")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("start")
        .join("SKILL.md");

    assert!(written.contains(&settings_path));
    assert!(written.contains(&plugin_skill));
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: session:start"));
}

#[test]
fn write_agent_bootstrap_writes_gemini_session_command() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Gemini).unwrap();

    let settings_path = dir.path().join(".gemini").join("settings.json");
    let command_path = dir
        .path()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("session")
        .join("start.toml");

    assert!(written.contains(&settings_path));
    assert!(written.contains(&command_path));
    let command = fs::read_to_string(command_path).unwrap();
    assert!(command.contains("harness session start"));
}

#[test]
fn write_agent_bootstrap_writes_opencode_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::OpenCode).unwrap();

    let hooks_path = dir.path().join(".opencode").join("hooks.json");
    let plugin_skill = dir
        .path()
        .join(".opencode")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("start")
        .join("SKILL.md");

    assert!(written.contains(&hooks_path));
    assert!(written.contains(&plugin_skill));
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: session:start"));
}

#[test]
fn write_agent_bootstrap_writes_vibe_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Vibe).unwrap();

    let hooks_path = dir.path().join(".vibe").join("hooks.json");
    let plugin_skill = dir
        .path()
        .join(".vibe")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("start")
        .join("SKILL.md");

    assert!(written.contains(&hooks_path));
    assert!(written.contains(&plugin_skill));
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: session:start"));
}

#[test]
fn write_agent_bootstrap_writes_copilot_hook_config_and_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Copilot).unwrap();

    let config_path = dir
        .path()
        .join(".github")
        .join("hooks")
        .join("harness.json");
    let plugin_skill = dir
        .path()
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("start")
        .join("SKILL.md");

    assert!(written.contains(&config_path));
    assert!(written.contains(&plugin_skill));
    let config = fs::read_to_string(config_path).unwrap();
    assert!(config.contains("\"version\": 1"));
    assert!(config.contains("\"preToolUse\""));
    assert!(config.contains("\"userPromptSubmitted\""));
    assert!(
        config.contains(
            "\"harness agents session-start --agent copilot --project-dir \\\"$PWD\\\"\""
        )
    );
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: session:start"));
}
