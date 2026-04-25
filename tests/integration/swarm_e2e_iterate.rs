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
        "Recording handling is mandatory.",
        "Recording triage is first, single-threaded, and never parallelized",
        "ledger row must cite a recording timestamp range",
        "The iteration ledger lives at",
        "Reuse one recording per iteration.",
        "Real findings only.",
        "TDD is mandatory:",
        "Fix the smallest independently committable row first.",
        "Rust gate is `rtk mise run check`.",
        "Do not bump versions inside the loop.",
        "Do not run the full UI suite.",
        "All repo workflow commands go through `rtk mise run",
        "Any file or path in generated notes, summaries, or handoffs must use markdown link format.",
        "Every commit uses `rtk git commit -sS`.",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "SKILL.md missing hard-rule phrase: {phrase}"
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
        meta.contains("driving the Harness Monitor swarm full-flow e2e"),
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
        "SKILL.md must point at references/recording-analysis.md"
    );
    assert!(
        body.contains("references/iteration-protocol.md"),
        "SKILL.md must point at references/iteration-protocol.md"
    );
    assert!(
        body.contains("agent.md"),
        "SKILL.md must point at the subagent contract"
    );
}

#[test]
fn recording_reference_carries_per_launch_checklist() {
    let body = read_repo_file(RECORDING_REF);
    let required_anchors = [
        "Process and lifecycle:",
        "First-frame state:",
        "Transitions between acts:",
        "Idle behavior:",
        "Suite speed and avoidable waiting:",
        "Animation and performance:",
        "Readability and accessibility:",
        "Interaction fidelity:",
        "Swarm-specific UI:",
        "Recording artifact:",
        "Time-to-first-frame target <= 2 s on M-series",
        "Toolbar back-and-forth size changes on FocusedValue updates",
        "`workerRefusal` toast fires at act11.",
        "`signalCollision` toast fires at act14.",
    ];
    for anchor in required_anchors {
        assert!(
            body.contains(anchor),
            "recording-analysis.md missing checklist anchor: {anchor}"
        );
    }
}

#[test]
fn recording_reference_carries_detection_recipes() {
    let body = read_repo_file(RECORDING_REF);
    let required_phrases = [
        "ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png",
        "ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov",
        "sampling 10 fps over 2 s windows",
        "Same element moving more than 2 pt without user action is drift",
        "mean luminance < 5 or unique-color count < 10",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "recording-analysis.md missing detection recipe phrase: {phrase}"
        );
    }
}

#[test]
fn recording_reference_carries_ux_heuristics_and_signatures() {
    let body = read_repo_file(RECORDING_REF);
    let heuristics = [
        "Communication failure:",
        "Attention thrash:",
        "Trust erosion:",
        "Friction:",
        "Cognitive load spike:",
        "Polish drift:",
        "Reliability smell:",
        "Iteration drag: avoidable waiting that makes the recording or loop longer than necessary.",
        "After the recording review, run the proof checklist",
    ];
    for heuristic in heuristics {
        assert!(
            body.contains(heuristic),
            "recording-analysis.md missing heuristic: {heuristic}"
        );
    }
    assert!(body.contains("Right:\n"), "missing Right: section header");
    assert!(body.contains("Wrong:\n"), "missing Wrong: section header");
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
fn subagent_body_pins_recording_first_invariants() {
    let body = read_repo_file(SUBAGENT_BODY);
    let required_phrases = [
        "Recording first: produce and process the `.mov` before all other artifacts.",
        "No parallel triage:",
        "Ledger rows need recording timestamps plus one secondary artifact.",
        "Reuse one recording per iteration.",
        "Real findings only.",
        "suite-speed findings",
        "TDD only:",
        "One ledger row per commit.",
        "No version bumps inside the loop.",
        "No full UI suite.",
        "rtk mise run",
        "rtk git commit -sS",
        "markdown link format",
        "1Password unavailable for signing means hard stop and return control.",
        "Never push unless explicitly asked.",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "agent.md missing invariant phrase: {phrase}"
        );
    }
}

#[test]
fn subagent_body_loads_skill_and_references() {
    let body = read_repo_file(SUBAGENT_BODY);
    assert!(
        body.contains("Load `Skill swarm-e2e-iterate`."),
        "agent.md must require loading the skill on every cycle"
    );
    assert!(
        body.contains("references/recording-analysis.md"),
        "agent.md must read recording-analysis.md before triage"
    );
    assert!(
        body.contains("references/iteration-protocol.md"),
        "agent.md must read iteration-protocol.md before lane execution"
    );
    assert!(
        body.contains("_artifacts/ledger.md"),
        "agent.md must point at the root _artifacts ledger"
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
    let claude_agent = repo_root().join(".claude/skills/swarm-e2e-iterate/agent.md");
    let codex_agent = repo_root().join(".agents/skills/swarm-e2e-iterate/agent.md");

    for path in [&claude_skill, &codex_skill, &claude_agent, &codex_agent] {
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
    let claude_agent_body = fs::read_to_string(&claude_agent).expect("read Claude agent mirror");
    let codex_agent_body = fs::read_to_string(&codex_agent).expect("read Codex agent mirror");
    assert!(claude.contains("name: swarm-e2e-iterate"));
    assert!(codex.contains("name: swarm-e2e-iterate"));
    assert_eq!(claude, codex, "Claude and Codex skill mirrors should match");
    assert!(
        claude_agent_body.contains("Load `Skill swarm-e2e-iterate`."),
        "Claude agent mirror should keep the load order"
    );
    assert_eq!(
        claude_agent_body, codex_agent_body,
        "Claude and Codex agent mirrors should match"
    );
}

#[test]
fn claude_agent_contract_points_at_canonical_source() {
    let body = read_repo_file(".claude/agents/swarm-e2e-iterator.md");
    assert!(
        body.contains("Load `Skill swarm-e2e-iterate`."),
        "Claude agent contract must keep the load order"
    );
    assert!(
        body.contains("agents/skills/swarm-e2e-iterate/agent.md")
            || body.contains("references/recording-analysis.md"),
        "Claude agent contract must remain the swarm-e2e-iterate delegation surface"
    );
}

#[test]
fn references_dir_holds_required_companions() {
    let dir = repo_root().join(SKILL_DIR).join("references");
    let expected = ["recording-analysis.md", "iteration-protocol.md"];
    for name in expected {
        let path = dir.join(name);
        assert!(
            path.is_file(),
            "expected references companion: {}",
            path.display()
        );
    }
}
