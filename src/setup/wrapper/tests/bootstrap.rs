use fs_err as fs;

use super::super::registrations::lifecycle_command;
use super::super::{planned_agent_bootstrap_files, write_agent_bootstrap};
use crate::feature_flags::RuntimeHookFlags;
use crate::hooks::adapters::HookAgent;

fn legacy_flags() -> RuntimeHookFlags {
    RuntimeHookFlags::all_enabled()
}

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
fn claude_runtime_config_contains_expected_lifecycle_commands() {
    let dir = tempfile::tempdir().unwrap();
    write_agent_bootstrap(dir.path(), HookAgent::Claude, &[], legacy_flags()).unwrap();
    let settings_path = dir.path().join(".claude").join("settings.json");
    let hooks: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(settings_path).unwrap()).unwrap();

    let commands = [
        (
            "PreCompact",
            lifecycle_command(HookAgent::Claude, "pre-compact"),
        ),
        (
            "SessionStart",
            lifecycle_command(HookAgent::Claude, "session-start"),
        ),
        (
            "SessionEnd",
            lifecycle_command(HookAgent::Claude, "session-stop"),
        ),
    ];

    for (event, expected) in commands {
        let actual = hooks["hooks"][event][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        assert_eq!(actual, expected, "{event} lifecycle command drifted");
    }

    let stop_command = hooks["hooks"]["Stop"][0]["hooks"][0]["command"]
        .as_str()
        .unwrap();
    assert_eq!(
        stop_command, "harness hook --agent claude suite:run guard-stop",
        "Stop lifecycle command drifted"
    );
}

fn assert_contains_all(haystack: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            haystack.contains(needle),
            "missing expected fragment {needle}"
        );
    }
}

#[test]
fn planned_agent_bootstrap_files_omit_codex_project_config() {
    let dir = tempfile::tempdir().unwrap();
    let planned = planned_agent_bootstrap_files(
        dir.path(),
        HookAgent::Codex,
        &[],
        RuntimeHookFlags::default(),
    );

    assert!(planned.is_empty());
}

#[test]
fn write_agent_bootstrap_skips_codex_project_outputs() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Codex, &[], legacy_flags()).unwrap();

    assert!(written.is_empty());
}

#[test]
fn write_agent_bootstrap_writes_only_claude_runtime_config() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Claude, &[], legacy_flags()).unwrap();

    let settings_path = dir.path().join(".claude").join("settings.json");
    let plugin_skill = dir
        .path()
        .join(".claude")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");
    assert!(written.contains(&settings_path));
    assert!(!written.contains(&plugin_skill));
    assert!(!plugin_skill.exists());
}

#[test]
fn write_agent_bootstrap_omits_gemini_session_command_by_default() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Gemini, &[], legacy_flags()).unwrap();

    let settings_path = dir.path().join(".gemini").join("settings.json");
    let command_path = dir
        .path()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");

    assert!(written.contains(&settings_path));
    assert!(!written.contains(&command_path));
    assert!(!command_path.exists());
}

#[test]
fn write_agent_bootstrap_writes_only_opencode_runtime_config() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::OpenCode, &[], legacy_flags()).unwrap();

    let hooks_path = dir.path().join(".opencode").join("hooks.json");
    let plugin_skill = dir
        .path()
        .join(".opencode")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");

    assert!(written.contains(&hooks_path));
    assert!(!written.contains(&plugin_skill));
    assert!(!plugin_skill.exists());
}

#[test]
fn write_agent_bootstrap_writes_only_vibe_runtime_config() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(dir.path(), HookAgent::Vibe, &[], legacy_flags()).unwrap();

    let hooks_path = dir.path().join(".vibe").join("hooks.json");
    let plugin_skill = dir
        .path()
        .join(".vibe")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");

    assert!(written.contains(&hooks_path));
    assert!(!written.contains(&plugin_skill));
    assert!(!plugin_skill.exists());
}

#[test]
fn write_agent_bootstrap_writes_only_copilot_runtime_config() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Copilot, &[], legacy_flags()).unwrap();

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
        .join("harness")
        .join("SKILL.md");

    assert!(written.contains(&config_path));
    assert!(!written.contains(&plugin_skill));
    let config = fs::read_to_string(config_path).unwrap();
    assert_contains_all(
        &config,
        &[
            "\"version\": 1",
            "\"preToolUse\"",
            "\"userPromptSubmitted\"",
            "\"harness agents session-start --agent copilot --project-dir \\\"$PWD\\\"\"",
        ],
    );
    assert!(!plugin_skill.exists());
}

#[test]
fn harness_bootstrap_only_adds_suite_hooks_when_all_enabled() {
    let dir = tempfile::tempdir().unwrap();
    write_agent_bootstrap(
        dir.path(),
        HookAgent::Claude,
        &[],
        RuntimeHookFlags::all_enabled(),
    )
    .unwrap();
    let settings_path = dir.path().join(".claude").join("settings.json");
    let baseline = fs::read_to_string(&settings_path).unwrap();
    assert!(baseline.contains("guard-stop"));
}

#[test]
fn default_flags_omit_optional_suite_hooks_in_claude_settings_json() {
    let dir = tempfile::tempdir().unwrap();
    write_agent_bootstrap(
        dir.path(),
        HookAgent::Claude,
        &[],
        RuntimeHookFlags::default(),
    )
    .unwrap();
    let settings = fs::read_to_string(dir.path().join(".claude").join("settings.json")).unwrap();
    assert!(!settings.contains("guard-stop"));
    assert!(!settings.contains("context-agent"));
    assert!(!settings.contains("validate-agent"));
    assert!(!settings.contains("tool-failure"));
    assert!(settings.contains("tool-guard"));
}

#[test]
fn write_agent_bootstrap_skips_gemini_hook_config_when_requested() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(
        dir.path(),
        HookAgent::Gemini,
        &[HookAgent::Gemini],
        legacy_flags(),
    )
    .unwrap();

    let settings_path = dir.path().join(".gemini").join("settings.json");
    let command_path = dir
        .path()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");

    assert!(!written.contains(&settings_path));
    assert!(!settings_path.exists());
    assert!(!written.contains(&command_path));
    assert!(!command_path.exists());
}

#[test]
fn write_agent_bootstrap_removes_existing_gemini_hook_config_when_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let settings_path = dir.path().join(".gemini").join("settings.json");
    fs::create_dir_all(settings_path.parent().unwrap()).unwrap();
    fs::write(
        &settings_path,
        r#"{"hooks":{"BeforeTool":[{"matcher":".*"}]}}"#,
    )
    .unwrap();

    let written = write_agent_bootstrap(
        dir.path(),
        HookAgent::Gemini,
        &[HookAgent::Gemini],
        legacy_flags(),
    )
    .unwrap();

    let command_path = dir
        .path()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");

    assert!(!written.contains(&settings_path));
    assert!(!settings_path.exists());
    assert!(!written.contains(&command_path));
    assert!(!command_path.exists());
}

#[test]
fn write_agent_bootstrap_skips_copilot_hook_config_when_requested() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(
        dir.path(),
        HookAgent::Copilot,
        &[HookAgent::Copilot],
        legacy_flags(),
    )
    .unwrap();

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
        .join("harness")
        .join("SKILL.md");

    assert!(!written.contains(&config_path));
    assert!(!config_path.exists());
    assert!(!written.contains(&plugin_skill));
    assert!(!plugin_skill.exists());
}
