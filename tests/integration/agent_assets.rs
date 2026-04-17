use std::fs;

use harness::agents::assets::{AgentAssetTarget, write_agent_target_outputs};
use tempfile::tempdir;

const MANAGED_ROOTS: &[&str] = &[
    ".claude/skills",
    ".claude/plugins",
    ".agents/skills",
    ".agents/plugins",
    ".gemini/commands",
    ".github/hooks",
    ".vibe/skills",
    ".vibe/plugins",
    ".opencode/skills",
    ".opencode/plugins",
    "plugins",
];

const CLAUDE_MD_ROOTS: &[&str] = &[".claude/skills", ".claude/plugins"];

#[test]
fn every_managed_root_gets_agents_md_after_generate() {
    let tmp = tempdir().expect("tempdir");
    write_agent_target_outputs(tmp.path(), AgentAssetTarget::All).expect("generate");

    for root in MANAGED_ROOTS {
        let marker = tmp.path().join(root).join("AGENTS.md");
        assert!(
            marker.is_file(),
            "missing AGENTS.md in managed root {root} at {}",
            marker.display()
        );
    }
}

#[test]
fn claude_specific_roots_also_get_claude_md() {
    let tmp = tempdir().expect("tempdir");
    write_agent_target_outputs(tmp.path(), AgentAssetTarget::All).expect("generate");

    for root in CLAUDE_MD_ROOTS {
        let marker = tmp.path().join(root).join("CLAUDE.md");
        assert!(
            marker.is_file(),
            "missing CLAUDE.md in claude root {root} at {}",
            marker.display()
        );
    }
}

#[test]
fn local_claude_skill_sources_render_as_symlinks() {
    let tmp = tempdir().expect("tempdir");
    write_agent_target_outputs(tmp.path(), AgentAssetTarget::All).expect("generate");

    for name in [
        "swiftui-api-patterns",
        "swiftui-design-rules",
        "swiftui-performance-macos",
        "swiftui-platform-rules",
    ] {
        let link = tmp.path().join(".claude/skills").join(name);
        let metadata = fs::symlink_metadata(&link)
            .unwrap_or_else(|_| panic!("missing symlink {}", link.display()));
        assert!(
            metadata.file_type().is_symlink(),
            "{} should be a symlink, got {:?}",
            link.display(),
            metadata.file_type()
        );
        let target =
            fs::read_link(&link).unwrap_or_else(|_| panic!("read_link {}", link.display()));
        assert_eq!(
            target.to_string_lossy(),
            format!("../../local-skills/claude/{name}"),
            "unexpected symlink target for {name}"
        );
    }
}
