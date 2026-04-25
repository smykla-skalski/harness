//! Integration tests that lock the swarm-e2e-iterate surface against drift.
//! The canonical skill is split across skill.yaml, body.md, agent.md, and
//! references/*.md so each test points at the file that owns the asserted text.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use tempfile::tempdir;

const SKILL_DIR: &str = "agents/skills/swarm-e2e-iterate";
const SKILL_META: &str = "agents/skills/swarm-e2e-iterate/skill.yaml";
const SKILL_BODY: &str = "agents/skills/swarm-e2e-iterate/body.md";
const SUBAGENT_BODY: &str = "agents/skills/swarm-e2e-iterate/agent.md";
const RECORDING_REF: &str = "agents/skills/swarm-e2e-iterate/references/recording-analysis.md";
const PROTOCOL_REF: &str = "agents/skills/swarm-e2e-iterate/references/iteration-protocol.md";
const CHECKLIST_REF: &str = "agents/skills/swarm-e2e-iterate/references/recording-checklist.md";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn read_repo_file(relative: &str) -> String {
    let path = repo_root().join(relative);
    fs::read_to_string(&path).unwrap_or_else(|err| {
        panic!("failed to read {}: {err}", path.display());
    })
}

#[test]
fn skill_body_carries_hard_rules() {
    let body = read_repo_file(SKILL_BODY);
    let required_phrases = [
        "Triage the `.mov` before logs",
        "Reuse one recording per iteration.",
        "TDD required: red, fix, green, gate, signed commit",
        "rtk mise run",
        "rtk git commit -sS",
        "No version bumps inside the loop.",
        "No full UI suite.",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "body.md missing hard-rule phrase: {phrase}"
        );
    }
}

#[test]
fn skill_metadata_carries_expected_frontmatter() {
    let meta = read_repo_file(SKILL_META);
    assert!(
        meta.contains("name: swarm-e2e-iterate"),
        "skill.yaml must keep the canonical name"
    );
    assert!(
        meta.contains("Harness Monitor swarm full-flow e2e loop"),
        "skill.yaml must keep the canonical description"
    );
    assert!(
        meta.contains("allowed-tools: Bash, Read, Edit, Write, Skill, Agent"),
        "skill.yaml must keep the canonical tool list"
    );
}

#[test]
fn skill_body_delegates_to_references() {
    let body = read_repo_file(SKILL_BODY);
    assert!(
        body.contains("references/recording-analysis.md"),
        "body.md must point at references/recording-analysis.md"
    );
    assert!(
        body.contains("references/recording-checklist.md"),
        "body.md must point at references/recording-checklist.md"
    );
    assert!(
        body.contains("references/iteration-protocol.md"),
        "body.md must point at references/iteration-protocol.md"
    );
}

#[test]
fn skill_body_consumes_emitted_checklist() {
    let body = read_repo_file(SKILL_BODY);
    assert!(
        body.contains("recording-triage/checklist.md"),
        "body.md must direct the agent to read the emitted checklist.md"
    );
    assert!(
        body.contains("needs-verification"),
        "body.md must call out re-watching needs-verification rows"
    );
}

#[test]
fn recording_reference_carries_detection_thresholds() {
    let body = read_repo_file(RECORDING_REF);
    let required_phrases = [
        "## Detection thresholds",
        "frame-gaps.sh",
        "auto-keyframes.sh",
        "detect-dead-head-tail.sh",
        "Gap > 50 ms during expected motion is a hitch.",
        "Gap > 250 ms without a clear cause is a stall.",
        "Gap > 2 s mid-run outside known waits is a freeze.",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "recording-analysis.md missing detection-threshold phrase: {phrase}"
        );
    }
}

#[test]
fn checklist_reference_carries_automation_map() {
    let body = read_repo_file(CHECKLIST_REF);
    let required_phrases = [
        "## Automation map",
        "frame-gaps.json",
        "act-timing.json",
        "act-identifiers.json",
        "launch-args.json",
        "layout-drift.json",
        "Tier-4 rows always emit `needs-verification`",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "recording-checklist.md missing automation-map phrase: {phrase}"
        );
    }
}

#[test]
fn protocol_reference_carries_ledger_schema() {
    let body = read_repo_file(PROTOCOL_REF);
    assert!(body.contains("# Swarm e2e iteration ledger"));
    assert!(body.contains(
        "| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |"
    ));
    assert!(
        body.contains("| L-0001 | Open | high | review-state | 1 | - | mm:ss-mm:ss (launch 2)"),
        "iteration-protocol.md must keep the canonical example ledger row"
    );
}

#[test]
fn protocol_reference_carries_loop_and_fix_protocols() {
    let body = read_repo_file(PROTOCOL_REF);
    let required_phrases = [
        "## Loop Protocol",
        "## Fix Protocol",
        "## Escape Hatches",
        "## Anti-Patterns",
        "## Version Policy",
        "## Done Bar",
        "Recording-first triage:",
        "Confirm red.",
        "Confirm green on the targeted test.",
        "Verify signature with `rtk git log --show-signature -1`",
        "Signed-off-by: Bart Smykla <bartek@smykla.com>",
        "rtk mise run e2e:swarm:triage:recording:test",
        "rtk mise run monitor:macos:tools:test:e2e",
        "rtk mise run test:integration",
        "rtk mise run check",
        "rtk mise run monitor:macos:lint",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "iteration-protocol.md missing phrase: {phrase}"
        );
    }
}

#[test]
fn subagent_body_keeps_pointer_contract() {
    let body = read_repo_file(SUBAGENT_BODY);
    assert!(
        body.contains("rtk mise run"),
        "agent.md must call out rtk mise run as the workflow shell"
    );
    assert!(
        body.contains("rtk git commit -sS"),
        "agent.md must mandate signed sign-off commits"
    );
    assert!(
        body.contains("TDD required"),
        "agent.md must keep the TDD-required invariant"
    );
}

#[test]
fn ledger_initial_schema_round_trips() {
    let tmp = tempdir().expect("tempdir");
    let ledger_path = tmp.path().join("ledger.md");
    write_initial_ledger(&ledger_path, 1, "dry-run", "passed", "1970-01-01T00:00:00Z");

    let written = fs::read_to_string(&ledger_path).expect("read");
    assert!(written.starts_with("# Swarm e2e iteration ledger\n"));
    assert!(written.contains("- Iteration: 1\n"));
    assert!(written.contains("- Last run slug: dry-run\n"));
    assert!(written.contains("- Last status: passed\n"));
    assert!(written.contains(
        "| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |"
    ));
    assert!(written.contains("|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|"));
}

/// Minimal ledger initializer that mirrors the §6 schema. Kept inline so the
/// test does not depend on a runtime path inside the harness binary.
fn write_initial_ledger(
    path: &Path,
    iteration: u32,
    slug: &str,
    status: &str,
    terminated_at: &str,
) {
    let mut file = fs::File::create(path).expect("create ledger");
    let body = format!(
        concat!(
            "# Swarm e2e iteration ledger\n\n",
            "- Iteration: {iteration}\n",
            "- Last run slug: {slug}\n",
            "- Last status: {status}\n",
            "- Last terminated at: {terminated_at}\n\n",
            "| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |\n",
            "|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|\n",
        ),
        iteration = iteration,
        slug = slug,
        status = status,
        terminated_at = terminated_at,
    );
    file.write_all(body.as_bytes()).expect("write ledger");
}

#[test]
fn mise_toml_publishes_recording_triage_tasks() {
    let mise = read_repo_file(".mise.toml");
    assert!(mise.contains("[tasks.\"e2e:swarm:triage:recording\"]"));
    assert!(mise.contains("[tasks.\"e2e:swarm:triage:recording:test\"]"));
    assert!(mise.contains("./scripts/e2e/recording-triage/run-all.sh"));
    assert!(mise.contains("./scripts/e2e/recording-triage/tests/run-all.sh"));
    let depends_count = mise.matches("\"monitor:macos:tools:build:e2e\"").count();
    assert!(
        depends_count >= 2,
        "expected at least two depends entries pointing at \
         monitor:macos:tools:build:e2e (one per recording-triage task); got {depends_count}"
    );
}

#[test]
fn generated_skill_mirrors_follow_the_canonical_source() {
    let claude_skill = repo_root().join(".claude/skills/swarm-e2e-iterate/SKILL.md");
    let codex_skill = repo_root().join(".agents/skills/swarm-e2e-iterate/SKILL.md");
    let claude_checklist =
        repo_root().join(".claude/skills/swarm-e2e-iterate/references/recording-checklist.md");
    let codex_checklist =
        repo_root().join(".agents/skills/swarm-e2e-iterate/references/recording-checklist.md");

    for path in [
        &claude_skill,
        &codex_skill,
        &claude_checklist,
        &codex_checklist,
    ] {
        let meta = fs::symlink_metadata(path)
            .unwrap_or_else(|err| panic!("expected generated file at {}: {err}", path.display()));
        assert!(
            !meta.file_type().is_symlink(),
            "generated mirror must be a file tree, not a symlink: {}",
            path.display()
        );
        assert!(path.is_file(), "expected generated file: {}", path.display());
    }

    let claude = fs::read_to_string(&claude_skill).expect("read Claude mirror");
    let codex = fs::read_to_string(&codex_skill).expect("read Codex mirror");
    assert!(claude.contains("name: swarm-e2e-iterate"));
    assert!(codex.contains("name: swarm-e2e-iterate"));
    assert_eq!(claude, codex, "Claude and Codex skill mirrors should match");

    let claude_checklist_body = fs::read_to_string(&claude_checklist).expect("read mirror");
    let codex_checklist_body = fs::read_to_string(&codex_checklist).expect("read mirror");
    assert!(
        claude_checklist_body.contains("## Automation map"),
        "Claude mirror must inherit the automation-map table"
    );
    assert_eq!(
        claude_checklist_body, codex_checklist_body,
        "Claude and Codex checklist mirrors must match"
    );
}

#[test]
fn references_dir_holds_required_companions() {
    let dir = repo_root().join(SKILL_DIR).join("references");
    let expected = [
        "recording-analysis.md",
        "recording-checklist.md",
        "iteration-protocol.md",
    ];
    for name in expected {
        let path = dir.join(name);
        assert!(
            path.is_file(),
            "expected references companion: {}",
            path.display()
        );
    }
}
