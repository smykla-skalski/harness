use std::fs;
use std::path::Path;

use assert_cmd::Command;
use predicates::str::contains;
use tempfile::tempdir;

fn write_file(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent dirs");
    }
    fs::write(path, contents).expect("write fixture");
}

fn read_file(path: &Path) -> String {
    fs::read_to_string(path).expect("read patched config")
}

fn assert_single_aff_commands(config: &str, agent: &str) {
    let repo_policy = format!("aff repo-policy --agent {agent}");
    let session_start = format!("aff session-start --agent {agent}");

    assert!(config.contains(&repo_policy), "missing repo-policy command");
    assert!(
        config.contains(&session_start),
        "missing session-start command"
    );
    assert_eq!(
        config.matches(&repo_policy).count(),
        1,
        "repo-policy duplicated"
    );
    assert_eq!(
        config.matches(&session_start).count(),
        1,
        "session-start duplicated"
    );
}

#[test]
fn bootstrap_patches_claude_settings_with_aff_hooks() {
    let dir = tempdir().expect("tempdir");
    let settings_path = dir.path().join(".claude").join("settings.json");
    write_file(
        &settings_path,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "harness hook --agent claude suite:run tool-guard"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "harness agents session-start --agent claude --project-dir \"$CLAUDE_PROJECT_DIR\""
          }
        ]
      }
    ]
  }
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "bootstrap",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--agents",
            "claude",
        ])
        .assert()
        .success();

    let updated = read_file(&settings_path);
    assert!(updated.contains("harness hook --agent claude suite:run tool-guard"));
    assert_single_aff_commands(&updated, "claude");
}

#[test]
fn bootstrap_patches_codex_hooks_with_aff_hooks() {
    let dir = tempdir().expect("tempdir");
    let hooks_path = dir.path().join(".codex").join("hooks.json");
    write_file(
        &hooks_path,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "harness hook --agent codex suite:run tool-guard",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "harness agents session-start --agent codex --project-dir \"$PWD\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "bootstrap",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--agents",
            "codex",
        ])
        .assert()
        .success();

    let updated = read_file(&hooks_path);
    assert!(updated.contains("harness hook --agent codex suite:run tool-guard"));
    assert_single_aff_commands(&updated, "codex");
}

#[test]
fn bootstrap_patches_gemini_settings_with_aff_hooks() {
    let dir = tempdir().expect("tempdir");
    let settings_path = dir.path().join(".gemini").join("settings.json");
    write_file(
        &settings_path,
        r#"{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "harness hook --agent gemini suite:run tool-guard",
            "timeout": 5000
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "harness agents session-start --agent gemini --project-dir \"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}\"",
            "timeout": 5000
          }
        ]
      }
    ]
  }
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "bootstrap",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--agents",
            "gemini",
        ])
        .assert()
        .success();

    let updated = read_file(&settings_path);
    assert!(updated.contains("harness hook --agent gemini suite:run tool-guard"));
    assert_single_aff_commands(&updated, "gemini");
}

#[test]
fn bootstrap_patches_copilot_hooks_with_aff_hooks() {
    let dir = tempdir().expect("tempdir");
    let config_path = dir
        .path()
        .join(".github")
        .join("hooks")
        .join("harness.json");
    write_file(
        &config_path,
        r#"{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "type": "command",
        "bash": "harness hook --agent copilot suite:run tool-guard",
        "cwd": ".",
        "timeoutSec": 30
      }
    ],
    "sessionStart": [
      {
        "type": "command",
        "bash": "harness agents session-start --agent copilot --project-dir \"$PWD\"",
        "cwd": ".",
        "timeoutSec": 30
      }
    ]
  }
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "bootstrap",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--agents",
            "copilot",
        ])
        .assert()
        .success();

    let updated = read_file(&config_path);
    assert!(updated.contains("harness hook --agent copilot suite:run tool-guard"));
    assert_single_aff_commands(&updated, "copilot");
}

#[test]
fn bootstrap_patches_vibe_hooks_with_aff_hooks() {
    let dir = tempdir().expect("tempdir");
    let hooks_path = dir.path().join(".vibe").join("hooks.json");
    write_file(
        &hooks_path,
        r#"{
  "registrations": [
    {
      "name": "tool-guard",
      "event": "tool.execute.before",
      "command": "harness hook --agent vibe suite:run tool-guard",
      "matcher": ".*"
    },
    {
      "name": "session-start",
      "event": "session.created",
      "command": "harness agents session-start --agent vibe --project-dir \"$PWD\""
    }
  ]
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "bootstrap",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--agents",
            "vibe",
        ])
        .assert()
        .success();

    let updated = read_file(&hooks_path);
    assert!(updated.contains("harness hook --agent vibe suite:run tool-guard"));
    assert_single_aff_commands(&updated, "vibe");
}

#[test]
fn bootstrap_patches_opencode_hooks_with_aff_hooks() {
    let dir = tempdir().expect("tempdir");
    let hooks_path = dir.path().join(".opencode").join("hooks.json");
    write_file(
        &hooks_path,
        r#"{
  "registrations": [
    {
      "name": "tool-guard",
      "event": "tool.execute.before",
      "command": "harness hook --agent opencode suite:run tool-guard",
      "matcher": ".*"
    },
    {
      "name": "session-start",
      "event": "session.created",
      "command": "harness agents session-start --agent opencode --project-dir \"$PWD\""
    }
  ]
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "bootstrap",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--agents",
            "opencode",
        ])
        .assert()
        .success();

    let updated = read_file(&hooks_path);
    assert!(updated.contains("harness hook --agent opencode suite:run tool-guard"));
    assert_single_aff_commands(&updated, "opencode");
}

#[test]
fn generate_check_detects_and_then_accepts_aff_runtime_hooks() {
    let dir = tempdir().expect("tempdir");
    let hooks_path = dir.path().join(".codex").join("hooks.json");
    write_file(
        &hooks_path,
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "harness hook --agent codex suite:run tool-guard",
            "timeout": 10
          }
        ]
      }
    ]
  }
}"#,
    );

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "agents",
            "generate",
            "--check",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--target",
            "codex",
        ])
        .assert()
        .failure()
        .stderr(contains(".codex/hooks.json"));

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "agents",
            "generate",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--target",
            "codex",
        ])
        .assert()
        .success();

    Command::cargo_bin("aff")
        .expect("aff binary")
        .args([
            "setup",
            "agents",
            "generate",
            "--check",
            "--project-dir",
            dir.path().to_str().expect("path"),
            "--target",
            "codex",
        ])
        .assert()
        .success();
}
