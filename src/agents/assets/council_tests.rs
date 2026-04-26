use std::path::PathBuf;

use regex::Regex;

use crate::infra::io::read_text;

use super::AgentAssetTarget;
use super::model::repo_root;
use super::planning::plan_outputs;

const COUNCIL_PERSONAS: &[&str] = &[
    "antirez-simplicity-reviewer",
    "tef-deletability-reviewer",
    "muratori-perf-reviewer",
    "hebert-resilience-reviewer",
    "meadows-systems-advisor",
    "chin-strategy-advisor",
    "king-type-reviewer",
    "hughes-pbt-advisor",
    "evans-ddd-reviewer",
    "fp-structure-reviewer",
    "wayne-spec-advisor",
    "iac-craft-reviewer",
    "test-architect",
    "gregg-perf-reviewer",
    "ai-quality-advisor",
    "cicd-build-advisor",
    "eidhof-swiftui-reviewer",
    "ash-cocoa-runtime-reviewer",
    "simmons-mac-craft-reviewer",
    "norman-affordance-reviewer",
    "tognazzini-fpid-reviewer",
    "krug-usability-reviewer",
    "nielsen-heuristics-reviewer",
    "watson-a11y-reviewer",
    "head-motion-reviewer",
    "siracusa-mac-critic",
    "tufte-density-reviewer",
];

fn claude_council_skill_path() -> PathBuf {
    repo_root()
        .join(".claude")
        .join("plugins")
        .join("council")
        .join("skills")
        .join("council")
        .join("SKILL.md")
}

fn portable_council_skill_path() -> PathBuf {
    repo_root()
        .join("plugins")
        .join("council")
        .join("skills")
        .join("council")
        .join("SKILL.md")
}

fn codex_council_skill_metadata_path() -> PathBuf {
    repo_root()
        .join("plugins")
        .join("council")
        .join("skills")
        .join("council")
        .join("agents")
        .join("openai.yaml")
}

#[test]
fn claude_council_plugin_skill_preserves_all_yaml_keys_and_tools() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Claude, &[]).expect("assets plan succeeds");
    let skill = claude_council_skill_path();
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("Claude council plugin skill should be planned");

    assert!(rendered.contains("name: council"));
    assert!(rendered.contains("argument-hint:"));
    assert!(rendered.contains("core|all|debate"));
    assert!(rendered.contains("allowed-tools:"));
    for tool in [
        "Agent",
        "AskUserQuestion",
        "Read",
        "Grep",
        "Glob",
        "Bash",
        "Write",
        "Edit",
    ] {
        assert!(
            rendered.contains(tool),
            "Claude council SKILL.md frontmatter should retain `{tool}` from skill.yaml"
        );
    }
    assert!(rendered.contains("disable-model-invocation: true"));
    assert!(rendered.contains("user-invocable: true"));
    assert!(rendered.contains("via AskUserQuestion"));
}

#[test]
fn codex_council_plugin_uses_codex_native_orchestration() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Codex, &[]).expect("assets plan succeeds");
    let skill = portable_council_skill_path();
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("Codex council plugin skill should be planned");

    assert!(rendered.contains("name: council"));
    assert!(rendered.contains("spawn_agent"));
    assert!(rendered.contains("wait_agent"));
    assert!(rendered.contains("agent_type: default"));
    assert!(
        rendered.contains("read `agents/<persona>.md`"),
        "Codex council skill should brief generic subagents with persona files"
    );
    assert!(
        !rendered.contains("$ARGUMENTS"),
        "Codex skill should not carry Claude slash-command argument syntax"
    );
    assert!(
        !rendered.contains("AskUserQuestion"),
        "Codex skill should not carry Claude-only approval tool text"
    );
    assert!(
        !rendered.contains("allowed-tools:"),
        "Codex skill frontmatter should not carry Claude-only tool constraints"
    );

    let metadata = codex_council_skill_metadata_path();
    let metadata_body = planned
        .iter()
        .find_map(|output| output.files.get(&metadata))
        .expect("Codex council openai.yaml should be planned");
    assert!(metadata_body.contains("display_name:"));
    assert!(metadata_body.contains("default_prompt:"));
}

#[test]
fn council_plugin_manifest_version_matches_canonical_yaml() {
    let canonical_yaml = read_text(
        &repo_root()
            .join("agents")
            .join("plugins")
            .join("council")
            .join("plugin.yaml"),
    )
    .expect("canonical council plugin.yaml reads");
    let canonical_version = canonical_yaml
        .lines()
        .find_map(|line| line.strip_prefix("version: "))
        .expect("canonical plugin.yaml carries `version:` line")
        .trim();

    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::All, &[]).expect("assets plan succeeds");
    for manifest_rel in [
        repo_root()
            .join(".claude")
            .join("plugins")
            .join("council")
            .join(".claude-plugin")
            .join("plugin.json"),
        repo_root()
            .join("plugins")
            .join("council")
            .join(".claude-plugin")
            .join("plugin.json"),
        repo_root()
            .join("plugins")
            .join("council")
            .join(".codex-plugin")
            .join("plugin.json"),
    ] {
        let rendered = planned
            .iter()
            .find_map(|output| output.files.get(&manifest_rel))
            .unwrap_or_else(|| panic!("manifest should be planned: {}", manifest_rel.display()));
        assert!(
            rendered.contains(&format!("\"version\": \"{canonical_version}\"")),
            "{} must carry version `{canonical_version}` from plugin.yaml; rendered:\n{rendered}",
            manifest_rel.display()
        );
    }
}

#[test]
fn council_skill_body_lists_all_personas() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Claude, &[]).expect("assets plan succeeds");
    let skill = claude_council_skill_path();
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("Claude council plugin skill should be planned");

    for persona in COUNCIL_PERSONAS {
        assert!(
            rendered.contains(persona),
            "council SKILL.md body must reference persona `{persona}`"
        );
    }
}

#[test]
fn codex_council_skill_body_lists_all_personas() {
    let planned =
        plan_outputs(&repo_root(), AgentAssetTarget::Codex, &[]).expect("assets plan succeeds");
    let skill = portable_council_skill_path();
    let rendered = planned
        .iter()
        .find_map(|output| output.files.get(&skill))
        .expect("Codex council plugin skill should be planned");

    for persona in COUNCIL_PERSONAS {
        assert!(
            rendered.contains(persona),
            "Codex council SKILL.md body must reference persona `{persona}`"
        );
    }
}

#[test]
fn rendered_council_relative_links_resolve_in_every_mirror() {
    let link_re = Regex::new(r"\[[^\]]*\]\(([^)]+)\)").expect("link regex compiles");

    let mirror_roots = [
        repo_root().join(".claude").join("plugins").join("council"),
        repo_root().join("plugins").join("council"),
    ];

    for mirror in mirror_roots {
        assert!(
            mirror.is_dir(),
            "expected rendered council mirror at {}",
            mirror.display()
        );

        let mut markdown_files = Vec::new();
        collect_markdown(&mirror, &mut markdown_files);
        assert!(
            !markdown_files.is_empty(),
            "no markdown files found under {}",
            mirror.display()
        );

        for source in &markdown_files {
            let body = read_text(source).expect("markdown reads");
            let parent = source.parent().expect("markdown parent");

            for capture in link_re.captures_iter(&body) {
                let target = &capture[1];
                let trimmed = target.split_once('#').map_or(target, |(path, _)| path);
                if trimmed.is_empty()
                    || trimmed.starts_with("http://")
                    || trimmed.starts_with("https://")
                    || trimmed.starts_with("mailto:")
                {
                    continue;
                }
                if !trimmed.ends_with(".md") {
                    continue;
                }
                let resolved = parent.join(trimmed);
                let canonical = resolved.canonicalize().unwrap_or(resolved.clone());
                assert!(
                    canonical.exists(),
                    "broken relative link in {}: `{trimmed}` resolves to {}",
                    source.display(),
                    canonical.display()
                );
            }
        }
    }
}

fn collect_markdown(root: &std::path::Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_markdown(&path, out);
        } else if path.extension().is_some_and(|extension| extension == "md") {
            out.push(path);
        }
    }
}
