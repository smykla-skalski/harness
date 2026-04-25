//! Integration tests that lock the swarm-e2e-iterate surface against drift:
//! the skill body must keep the verbatim §3/§4/§6 text the brief mandates,
//! the ledger schema must round-trip, and the new mise tasks must keep their
//! published names.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use tempfile::tempdir;

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
fn skill_body_carries_hard_rules_verbatim() {
    let body = read_repo_file("local-skills/claude/swarm-e2e-iterate/SKILL.md");
    let required_phrases = [
        "Recording handling is mandatory.",
        "The first triage step is the recording.",
        "Recording-first cannot be skipped, deferred, or run in parallel",
        "The recording must match the app lifecycle.",
        "Avoid duplicate expensive reruns.",
        "Real findings only.",
        "TDD is mandatory.",
        "Smallest independently committable chunk per fix.",
        "Right gate per stack.",
        "No version bumps inside iteration.",
        "No full UI suite.",
        "All commands through mise + rtk.",
        "Commit signing is strict.",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "skill body missing hard-rule phrase: {phrase}"
        );
    }
}

#[test]
fn skill_body_carries_per_launch_checklist_a_through_i() {
    let body = read_repo_file("local-skills/claude/swarm-e2e-iterate/SKILL.md");
    let required_anchors = [
        "**A. Process and lifecycle**",
        "**B. First-frame state**",
        "**C. State transitions between acts**",
        "**D. Idle behavior between acts**",
        "**E. Animation, performance, hitches**",
        "**F. Readability and accessibility**",
        "**G. Interaction fidelity**",
        "**H. Swarm-specific UI (cross-reference act markers act1..act16)**",
        "**I. Recording artifact verification**",
        "Time-to-first-frame from process spawn (target ≤ 2 s on M-series)",
        "Toolbar quantization stutter on FocusedValue updates",
        "workerRefusal toast must fire at act11",
        "signalCollision toast must fire at act14",
    ];
    for anchor in required_anchors {
        assert!(
            body.contains(anchor),
            "skill body missing checklist anchor: {anchor}"
        );
    }
}

#[test]
fn skill_body_carries_detection_recipes_verbatim() {
    let body = read_repo_file("local-skills/claude/swarm-e2e-iterate/SKILL.md");
    let required_phrases = [
        "ffmpeg -ss <ts> -i swarm-full-flow.mov -frames:v 1 -y <act>.png",
        "ffprobe -show_frames -of compact=p=0 swarm-full-flow.mov | awk -F= '/pkt_pts_time=/ {print $NF}'",
        "Sample 10 fps across 2 s windows",
        "If the same element shifts",
        "mean luminance is < 5",
    ];
    for phrase in required_phrases {
        assert!(
            body.contains(phrase),
            "skill body missing detection recipe: {phrase}"
        );
    }
}

#[test]
fn skill_body_carries_ledger_schema_verbatim() {
    let body = read_repo_file("local-skills/claude/swarm-e2e-iterate/SKILL.md");
    assert!(body.contains("# Swarm e2e iteration ledger"));
    assert!(body.contains(
        "| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |"
    ));
    assert!(body.contains("| L-0001 | Open | high | review-state | 1 | – | mm:ss-mm:ss (launch 2)"));
}

#[test]
fn skill_body_carries_ux_heuristics_and_signatures() {
    let body = read_repo_file("local-skills/claude/swarm-e2e-iterate/SKILL.md");
    let heuristics = [
        "Communication failure",
        "Attention thrash",
        "Trust erosion",
        "Friction",
        "Cognitive load spike",
        "Polish drift",
        "Reliability smell",
    ];
    for heuristic in heuristics {
        assert!(body.contains(heuristic), "missing heuristic: {heuristic}");
    }

    // Right vs Wrong section markers.
    assert!(body.contains("Right:\n"));
    assert!(body.contains("Wrong:\n"));
}

#[test]
fn subagent_body_lists_every_named_rule() {
    let body = read_repo_file("local-skills/claude/swarm-e2e-iterate/agent.md");
    let rules = [
        "recording-mandatory",
        "recording-first",
        "recording-no-fanout",
        "recording-supports",
        "recording-lifecycle",
        "recording-reuse",
        "real-findings-only",
        "tdd-mandatory",
        "smallest-chunk",
        "right-gate-per-stack",
        "no-version-bump",
        "no-full-ui-suite",
        "narrow-ui-test-runs",
        "mise-rtk-only",
        "no-rtk-proxy",
        "lint-no-grep",
        "rtk-env-prefix",
        "commit-signing-strict",
        "commit-message-rules",
        "no-push",
        "100-percent-implementation",
        "no-shortcuts",
        "no-deferring",
        "no-skipping",
        "root-cause-only",
        "longterm-fixes",
        "native-swiftui-first",
        "native-previews",
        "no-exec-in-shell",
        "no-abbreviations",
        "path-style",
        "worktree-per-worker",
    ];
    for rule in rules {
        assert!(body.contains(rule), "subagent missing rule: {rule}");
    }
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
    // Both tasks must depend on the e2e tool build so the Swift CLI is fresh.
    let depends_count = mise.matches("\"monitor:macos:tools:build:e2e\"").count();
    assert!(
        depends_count >= 2,
        "expected at least two depends entries pointing at \
         monitor:macos:tools:build:e2e (one per recording-triage task); got {depends_count}"
    );
}

#[test]
fn skills_symlink_points_at_local_source() {
    let symlink = repo_root().join(".claude/skills/swarm-e2e-iterate");
    let target = fs::read_link(&symlink).unwrap_or_else(|err| {
        panic!("expected symlink at {}: {err}", symlink.display());
    });
    assert_eq!(
        target.to_string_lossy(),
        "../../local-skills/claude/swarm-e2e-iterate"
    );
}

#[test]
fn agents_symlink_points_at_local_source() {
    let symlink = repo_root().join(".claude/agents/swarm-e2e-iterator.md");
    let target = fs::read_link(&symlink).unwrap_or_else(|err| {
        panic!("expected symlink at {}: {err}", symlink.display());
    });
    assert_eq!(
        target.to_string_lossy(),
        "../../local-skills/claude/swarm-e2e-iterate/agent.md"
    );
}
