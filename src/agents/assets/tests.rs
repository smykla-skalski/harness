use std::path::PathBuf;

use serde_json::json;

use crate::hooks::adapters::HookAgent;
use crate::infra::io::read_text;
use crate::setup::wrapper::PROJECT_PLUGIN_LAUNCHER;

use super::model::{RenderTarget, SkillDefinition, SkillSource, repo_root};
use super::planning::plan_outputs;
use super::render_skills::{render_skill_markdown, yaml_serialized_lines};
use super::{AgentAssetTarget, write_agent_target_outputs, write_suite_plugin_outputs};

fn sample_skill() -> SkillDefinition {
    SkillDefinition {
        root: PathBuf::from("agents/plugins/suite/skills/run"),
        source: SkillSource {
            name: "run".to_string(),
            description: "Execute suite runs through harness.".to_string(),
            argument_hint: Some("[suite-path]".to_string()),
            allowed_tools: Some(
                "Agent, AskUserQuestion, Bash, Edit, Glob, Read, Write".to_string(),
            ),
            disable_model_invocation: Some(true),
            user_invocable: Some(true),
            direct_skill_name: None,
            hooks: Some(json!({
                "PreToolUse": [
                    {
                        "matcher": ".*",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "harness hook --skill suite:run tool-guard"
                            }
                        ]
                    }
                ],
                "PostToolUse": [
                    {
                        "matcher": ".*",
                        "hooks": [
                            {
                                "type": "command",
                                "command": "harness hook --skill suite:run tool-result"
                            }
                        ]
                    }
                ]
            })),
        },
        body: "Run the suite through harness.".to_string(),
        codex: None,
    }
}

#[test]
fn agent_assets_round_trip_smoke_covers_public_surface() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_root = tmp.path();

    let written = write_agent_target_outputs(project_root, AgentAssetTarget::All)
        .expect("asset write succeeds");
    let claude_harness_skill = project_root
        .join(".claude")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");
    let codex_harness_skill = project_root
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");
    let gemini_command = project_root
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");
    let copilot_hook = project_root
        .join(".github")
        .join("hooks")
        .join("harness.json");
    let portable_suite_plugin = project_root
        .join("plugins")
        .join("suite")
        .join("plugin.json");
    assert!(written.contains(&claude_harness_skill));
    assert!(written.contains(&codex_harness_skill));
    assert!(written.contains(&gemini_command));
    assert!(written.contains(&copilot_hook));
    assert!(written.contains(&portable_suite_plugin));
    assert!(
        read_text(&codex_harness_skill)
            .expect("codex harness skill reads")
            .contains("name: harness")
    );
    assert!(
        read_text(&gemini_command)
            .expect("gemini command reads")
            .contains("harness session")
    );

    let suite_written = write_suite_plugin_outputs(project_root).expect("suite plugin writes");
    let claude_suite_plugin = project_root
        .join(".claude")
        .join("plugins")
        .join("suite")
        .join(".claude-plugin")
        .join("plugin.json");
    let launcher = project_root
        .join(".claude")
        .join("plugins")
        .join("suite")
        .join("harness");
    assert!(suite_written.contains(&claude_suite_plugin));
    assert!(suite_written.contains(&launcher));
    assert!(
        read_text(&claude_suite_plugin)
            .expect("suite manifest reads")
            .contains("\"name\": \"suite\"")
    );
    assert_eq!(
        read_text(&launcher).expect("launcher reads"),
        PROJECT_PLUGIN_LAUNCHER
    );
}

#[test]
fn render_skill_markdown_keeps_first_scalar_and_hook_entries() {
    let rendered =
        render_skill_markdown(RenderTarget::Claude, &sample_skill(), None).expect("skill renders");

    assert!(rendered.starts_with("---\nname: run\n"));
    assert!(rendered.contains("description: Execute suite runs through harness.\n"));
    assert!(rendered.contains("argument-hint:"));
    assert!(rendered.contains("[suite-path]"));
    assert!(rendered.contains("allowed-tools:"));
    assert!(rendered.contains("AskUserQuestion"));
    assert!(rendered.contains("hooks:\n"));
    assert!(rendered.contains("PreToolUse"));
    assert!(rendered.contains("PostToolUse"));
    assert!(rendered.contains("---\n\n"));
    assert!(rendered.contains("Run the suite through harness."));
}

#[test]
fn yaml_serialized_lines_drops_only_optional_document_marker() {
    let rendered =
        yaml_serialized_lines(&json!({"PreToolUse": []}), "hooks").expect("yaml serializes");

    assert_eq!(rendered.first().map(String::as_str), Some("PreToolUse: []"));
}

#[test]
fn portable_plugin_skill_omits_host_specific_hooks_and_question_tool() {
    let rendered = render_skill_markdown(RenderTarget::Portable, &sample_skill(), None)
        .expect("skill renders");

    assert!(rendered.starts_with("---\nname: run\n"));
    assert!(rendered.contains("allowed-tools: Agent, Bash, Edit, Glob, Read, Write\n"));
    assert!(!rendered.contains("AskUserQuestion"));
    assert!(!rendered.contains("\nhooks:\n"));
    assert!(!rendered.contains("--agent copilot"));
    assert!(!rendered.contains("--agent codex"));
}

#[test]
fn copilot_generation_includes_repo_hook_config() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Copilot, &[]).expect("assets plan succeeds");
    let hook_path = repo_root()
        .join(".github")
        .join("hooks")
        .join("harness.json");
    let hook_output = planned
        .iter()
        .find_map(|output| output.files.get(&hook_path))
        .expect("copilot hook config should be generated");

    assert!(hook_output.contains("\"version\": 1"));
    assert!(hook_output.contains("\"userPromptSubmitted\""));
    assert!(
        hook_output.contains(
            "\"harness agents session-start --agent copilot --project-dir \\\"$PWD\\\"\""
        )
    );
}

#[test]
fn shared_plugin_outputs_stay_portable_across_codex_and_copilot() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::All, &[]).expect("assets plan succeeds");
    let shared_skill = repo_root()
        .join("plugins")
        .join("suite")
        .join("skills")
        .join("create")
        .join("SKILL.md");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&shared_skill))
        .expect("shared plugin skill should be planned");

    assert!(!rendered.contains("--agent codex"));
    assert!(!rendered.contains("--agent copilot"));
    assert!(!rendered.contains("matcher: AskUserQuestion"));
    assert!(rendered.contains("user approval prompt"));
}

#[test]
fn harness_plugin_is_in_codex_marketplace() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Codex, &[]).expect("assets plan succeeds");
    let marketplace = repo_root()
        .join(".agents")
        .join("plugins")
        .join("marketplace.json");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&marketplace))
        .expect("codex marketplace should be planned");

    assert!(rendered.contains("\"name\": \"harness\""));
    assert!(rendered.contains("\"source\": \"local\""));
    assert!(rendered.contains("\"path\": \"./plugins/harness\""));
}

#[test]
fn codex_harness_plugin_skill_is_planned() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Codex, &[]).expect("assets plan succeeds");
    let skill = repo_root()
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("harness plugin skill should be planned");

    assert!(rendered.contains("name: harness"));
    assert!(rendered.contains("session join"));
}

#[test]
fn claude_harness_plugin_skill_is_planned() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Claude, &[]).expect("assets plan succeeds");
    let skill = repo_root()
        .join(".claude")
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("Claude harness plugin skill should be planned");

    assert!(rendered.contains("name: harness"));
    assert!(rendered.contains("AskUserQuestion"));
}

#[test]
fn gemini_harness_plugin_command_is_namespaced_under_harness() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Gemini, &[]).expect("assets plan succeeds");
    let command = repo_root()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&command))
        .expect("Gemini harness command should be planned");

    assert!(rendered.contains("multi-agent session"));
    assert!(rendered.contains("harness session"));
}

#[test]
fn copilot_harness_plugin_includes_cli_skill() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Copilot, &[]).expect("assets plan succeeds");
    let skill = repo_root()
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("cli")
        .join("SKILL.md");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("Copilot harness CLI skill should be planned");

    assert!(rendered.contains("name: cli"));
    assert!(rendered.contains("# Harness CLI reference"));
    assert!(rendered.contains("references/top-level-and-hidden.md"));
}

#[test]
fn claude_direct_skill_alias_uses_safe_frontmatter_name() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Claude, &[]).expect("assets plan succeeds");
    let skill = repo_root()
        .join(".claude")
        .join("skills")
        .join("harness-cli")
        .join("SKILL.md");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("claude alias skill should be planned");

    assert!(rendered.contains("name: harness-cli"));
    assert!(!rendered.contains("name: harness:cli"));
}

#[test]
fn codex_direct_skill_alias_uses_safe_frontmatter_name() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Codex, &[]).expect("assets plan succeeds");
    let skill = repo_root()
        .join(".agents")
        .join("skills")
        .join("harness-cli")
        .join("SKILL.md");
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("codex alias skill should be planned");

    assert!(rendered.contains("name: harness-cli"));
    assert!(!rendered.contains("name: harness:cli"));
}

#[test]
fn copilot_runtime_hook_config_can_be_skipped() {
    let planned = plan_outputs(
        &repo_root(),
        AgentAssetTarget::Copilot,
        &[HookAgent::Copilot],
    )
    .expect("assets plan succeeds");
    let hook_path = repo_root()
        .join(".github")
        .join("hooks")
        .join("harness.json");
    let plugin_skill = repo_root()
        .join("plugins")
        .join("harness")
        .join("skills")
        .join("harness")
        .join("SKILL.md");

    assert!(
        planned
            .iter()
            .all(|output| !output.files.contains_key(&hook_path)),
        "copilot hook config should be omitted when skipped"
    );
    assert!(
        planned
            .iter()
            .any(|output| output.files.contains_key(&plugin_skill)),
        "copilot plugin assets should still be generated"
    );
}
