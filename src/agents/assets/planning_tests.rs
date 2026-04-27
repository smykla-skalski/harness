use std::fs;
use std::path::Path;

use crate::hooks::adapters::HookAgent;
use super::AgentAssetTarget;
use super::model::repo_root;
use super::planning::{plan_outputs, plan_outputs_with_gemini_commands_legacy};

fn write(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent directories");
    }
    fs::write(path, content).expect("write file");
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
        hook_output.contains("\"harness agents session-start --agent copilot --project-dir \\\"$PWD\\\"\"")
    );
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
        plan_outputs_with_gemini_commands_legacy(&repo_root(), AgentAssetTarget::Gemini, &[], true)
            .expect("assets plan succeeds");
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
fn gemini_commands_are_omitted_from_default_plan() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::All, &[]).expect("assets plan succeeds");
    let command = repo_root()
        .join(".gemini")
        .join("commands")
        .join("harness")
        .join("harness.toml");

    assert!(
        planned
            .iter()
            .all(|output| !output.files.contains_key(&command)),
        "default plan should omit Gemini commands"
    );
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
fn plan_outputs_ignores_plugin_workspace_dirs_without_skill_definitions() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let repo_root = tmp.path();
    write(
        &repo_root.join("agents/plugins/council/plugin.yaml"),
        "name: council\ndescription: Council plugin\nversion: 1.0.0\n",
    );
    write(
        &repo_root.join("agents/plugins/council/skills/council/skill.yaml"),
        "name: council\ndescription: Council skill\n",
    );
    write(
        &repo_root.join("agents/plugins/council/skills/council/body.md"),
        "# Council\n\nCanonical skill body.\n",
    );
    write(
        &repo_root.join("agents/plugins/council/skills/council-workspace/evals.md"),
        "# Workspace artifacts live here.\n",
    );

    let planned =
        plan_outputs(repo_root, AgentAssetTarget::Claude, &[]).expect("assets plan succeeds");

    let manifest = repo_root
        .join(".claude")
        .join("plugins")
        .join("council")
        .join(".claude-plugin")
        .join("plugin.json");
    let skill = repo_root
        .join(".claude")
        .join("plugins")
        .join("council")
        .join("skills")
        .join("council")
        .join("SKILL.md");
    assert!(
        planned
            .iter()
            .any(|output| output.files.contains_key(&manifest)),
        "council plugin manifest should be planned"
    );
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("council plugin skill should be planned");
    assert!(rendered.contains("name: council"));
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
