use std::path::{Path, PathBuf};

use fs_err as fs;

use super::super::registrations::{build_codex_config, lifecycle_command};
use super::super::write_agent_bootstrap;
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
    assert_contains_all(
        &config,
        &[
            "\"audit-turn\"",
            "codex_hooks = true",
            "Hook definitions stay in hooks.json",
        ],
    );
    assert_contains_none(
        &config,
        &[
            "[hooks]",
            "session_start = [",
            "pre_compact = [",
            "session_end = [",
        ],
    );
}

fn assert_codex_hooks(hooks: &str) {
    assert_contains_all(
        hooks,
        &[
            "\"Stop\"",
            "\"UserPromptSubmit\"",
            "\"PreToolUse\"",
            "\"PostToolUse\"",
            "\"SubagentStart\"",
            "\"SubagentStop\"",
            "tool-guard",
            "tool-result",
        ],
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

fn assert_contains_none(haystack: &str, needles: &[&str]) {
    for needle in needles {
        assert!(
            !haystack.contains(needle),
            "unexpected fragment present {needle}"
        );
    }
}

fn assert_written_paths(written: &[PathBuf], expected: &[&Path]) {
    for path in expected {
        assert!(
            written.iter().any(|written_path| written_path == *path),
            "missing written path {}",
            path.display()
        );
    }
}

#[test]
fn write_agent_bootstrap_writes_codex_notify_config() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Codex, false, &[], legacy_flags()).unwrap();

    let plugin_skill = dir
        .path()
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");
    let hooks_path = dir.path().join(".codex").join("hooks.json");
    let config_path = dir.path().join(".codex").join("config.toml");

    assert_written_paths(&written, &[&plugin_skill, &hooks_path, &config_path]);

    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert_contains_all(&skill, &["name: harness"]);
    assert_codex_hooks(&fs::read_to_string(hooks_path).unwrap());
    let config = fs::read_to_string(config_path).unwrap();
    assert_contains_all(&config, &["\"audit-turn\"", "codex_hooks = true"]);
    assert_contains_none(&config, &["[hooks]"]);
}

#[test]
fn write_agent_bootstrap_writes_claude_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Claude, false, &[], legacy_flags()).unwrap();

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
    assert!(written.contains(&plugin_skill));
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: harness"));
}

#[test]
fn write_agent_bootstrap_omits_gemini_session_command_by_default() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Gemini, false, &[], legacy_flags()).unwrap();

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
fn write_agent_bootstrap_includes_gemini_session_command_when_requested() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Gemini, true, &[], legacy_flags()).unwrap();

    let settings_path = dir.path().join(".gemini").join("settings.json");
    let command_path = dir
        .path()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");

    assert!(written.contains(&settings_path));
    assert!(written.contains(&command_path));
    let command = fs::read_to_string(command_path).unwrap();
    assert!(command.contains("harness session"));
}

#[test]
fn write_agent_bootstrap_writes_opencode_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::OpenCode, false, &[], legacy_flags()).unwrap();

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
    assert!(written.contains(&plugin_skill));
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: harness"));
}

#[test]
fn write_agent_bootstrap_writes_vibe_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Vibe, false, &[], legacy_flags()).unwrap();

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
    assert!(written.contains(&plugin_skill));
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert!(skill.contains("name: harness"));
}

#[test]
fn write_agent_bootstrap_writes_copilot_hook_config_and_plugin_assets() {
    let dir = tempfile::tempdir().unwrap();
    let written =
        write_agent_bootstrap(dir.path(), HookAgent::Copilot, false, &[], legacy_flags()).unwrap();

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
    assert!(written.contains(&plugin_skill));
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
    let skill = fs::read_to_string(plugin_skill).unwrap();
    assert_contains_all(&skill, &["name: harness"]);
}

#[test]
fn harness_bootstrap_only_adds_suite_hooks_when_all_enabled() {
    let dir = tempfile::tempdir().unwrap();
    write_agent_bootstrap(
        dir.path(),
        HookAgent::Claude,
        false,
        &[],
        RuntimeHookFlags::all_enabled(),
    )
    .unwrap();
    let settings_path = dir.path().join(".claude").join("settings.json");
    let baseline = fs::read_to_string(&settings_path).unwrap();
    assert!(baseline.contains("guard-stop"));
}

#[test]
fn default_flags_omit_optional_suite_hooks_in_codex_hooks_json() {
    let dir = tempfile::tempdir().unwrap();
    write_agent_bootstrap(
        dir.path(),
        HookAgent::Codex,
        false,
        &[],
        RuntimeHookFlags::default(),
    )
    .unwrap();
    let hooks = fs::read_to_string(dir.path().join(".codex").join("hooks.json")).unwrap();
    assert!(!hooks.contains("guard-stop"));
    assert!(!hooks.contains("context-agent"));
    assert!(!hooks.contains("validate-agent"));
    assert!(hooks.contains("tool-guard"));
    assert!(hooks.contains("tool-result"));
}

#[test]
fn default_flags_omit_optional_suite_hooks_in_claude_settings_json() {
    let dir = tempfile::tempdir().unwrap();
    write_agent_bootstrap(
        dir.path(),
        HookAgent::Claude,
        false,
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
        true,
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
    assert!(written.contains(&command_path));
    assert!(command_path.is_file());
}

#[test]
fn write_agent_bootstrap_skips_copilot_hook_config_when_requested() {
    let dir = tempfile::tempdir().unwrap();
    let written = write_agent_bootstrap(
        dir.path(),
        HookAgent::Copilot,
        false,
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
    assert!(written.contains(&plugin_skill));
    assert!(plugin_skill.is_file());
}
