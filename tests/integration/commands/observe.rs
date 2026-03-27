// Integration tests for the `harness observe` command.
// Tests error paths and basic scan behavior with synthetic JSONL fixtures.

use std::fs::{self, File};
use std::io::Write;
use std::path::Path;

use harness::app::cli::Command;
use harness::observe::{ObserveArgs, ObserveFilterArgs, ObserveMode};
use harness::run::context::{CurrentRunRecord, RunLayout};
use harness::workspace::current_run_context_path_for_project;

use super::super::helpers::*;

fn default_filter() -> ObserveFilterArgs {
    ObserveFilterArgs {
        from_line: 0,
        from: None,
        focus: None,
        project_hint: None,
        json: false,
        summary: false,
        severity: None,
        category: None,
        exclude: None,
        fixable: false,
        mute: None,
        until_line: None,
        since_timestamp: None,
        until_timestamp: None,
        format: None,
        overrides: None,
        top_causes: None,
        output: None,
        output_details: None,
    }
}

fn scan_mode(session_id: &str, filter: ObserveFilterArgs) -> ObserveMode {
    ObserveMode::Scan {
        session_id: Some(session_id.into()),
        action: None,
        issue_id: None,
        since_line: None,
        value: None,
        range_a: None,
        range_b: None,
        codes: None,
        filter,
    }
}

fn dump_mode(session_id: &str) -> ObserveMode {
    ObserveMode::Dump {
        session_id: session_id.into(),
        context_line: None,
        context_window: 10,
        from_line: None,
        to_line: None,
        filter: None,
        role: None,
        tool_name: None,
        raw_json: false,
        project_hint: None,
    }
}

fn observe_args(mode: ObserveMode) -> ObserveArgs {
    ObserveArgs {
        agent: None,
        observe_id: "project-default".to_string(),
        mode,
    }
}

#[test]
fn scan_missing_session_returns_error() {
    let tmp = tempfile::tempdir().unwrap();
    let mut filter = default_filter();
    filter.project_hint = Some("nonexistent".into());

    let cmd = Command::Observe(observe_args(scan_mode("does-not-exist-ever", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI080");
    });
}

#[test]
fn dump_missing_session_returns_error() {
    let tmp = tempfile::tempdir().unwrap();

    let cmd = Command::Observe(observe_args(dump_mode("no-such-session")));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI080");
    });
}

#[test]
fn context_missing_session_returns_error() {
    let tmp = tempfile::tempdir().unwrap();

    let cmd = Command::Observe(observe_args(ObserveMode::Dump {
        session_id: "no-such-session".into(),
        context_line: Some(10),
        context_window: 5,
        from_line: None,
        to_line: None,
        filter: None,
        role: None,
        tool_name: None,
        raw_json: false,
        project_hint: None,
    }));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_err());
    });
}

fn write_session_fixture(tmp: &tempfile::TempDir, session_id: &str, lines: &[&str]) {
    let project_dir = tmp
        .path()
        .join(".claude")
        .join("projects")
        .join("test-project");
    fs::create_dir_all(&project_dir).unwrap();
    let session_file = project_dir.join(format!("{session_id}.jsonl"));
    let mut file = File::create(session_file).unwrap();
    for line in lines {
        writeln!(file, "{line}").unwrap();
    }
}

fn write_doctor_project(project_dir: &Path, legacy_lifecycle: bool) {
    let suite_dir = project_dir.join(".claude").join("plugins").join("suite");
    let hooks_dir = suite_dir.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    fs::write(suite_dir.join("harness"), "").unwrap();
    let hooks_json = if legacy_lifecycle {
        let session_start = [
            "harness",
            " setup",
            " session-start",
            " --project-dir \\\"$CLAUDE_PROJECT_DIR\\\"",
        ]
        .concat();
        format!(
            r#"{{"hooks":{{"SessionStart":[{{"hooks":[{{"type":"command","command":"{session_start}"}}]}}]}}}}"#
        )
    } else {
        r#"{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"harness pre-compact --project-dir \"$CLAUDE_PROJECT_DIR\""}]}],"SessionStart":[{"hooks":[{"type":"command","command":"harness agents session-start --agent claude --project-dir \"$CLAUDE_PROJECT_DIR\""}]}],"Stop":[{"hooks":[{"type":"command","command":"harness agents session-stop --agent claude --project-dir \"$CLAUDE_PROJECT_DIR\""}]}]}}"#
            .to_string()
    };
    fs::write(hooks_dir.join("hooks.json"), hooks_json).unwrap();
}

#[test]
fn scan_finds_build_error() {
    let tmp = tempfile::tempdir().unwrap();
    let tool_use = serde_json::json!({
        "message": {
            "role": "assistant",
            "content": [{
                "type": "tool_use",
                "id": "t1",
                "name": "Bash",
                "input": { "command": "cargo build" }
            }]
        }
    });
    let tool_result = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{
                "type": "tool_result",
                "tool_use_id": "t1",
                "content": [{ "type": "text", "text": "error[E0308]: mismatched types\n  expected u32" }]
            }]
        }
    });
    write_session_fixture(
        &tmp,
        "build-err-sess",
        &[
            &serde_json::to_string(&tool_use).unwrap(),
            &serde_json::to_string(&tool_result).unwrap(),
        ],
    );

    let mut filter = default_filter();
    filter.json = true;
    filter.summary = true;

    let cmd = Command::Observe(observe_args(scan_mode("build-err-sess", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
fn observe_doctor_accepts_current_project_wiring() {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp.path().join("project");
    write_doctor_project(&project_dir, false);
    let home = tmp.path().join("home");
    fs::create_dir_all(home.join(".claude").join("projects")).unwrap();
    let bin_dir = home.join(".local").join("bin");
    fs::create_dir_all(&bin_dir).unwrap();
    fs::write(bin_dir.join("harness"), "").unwrap();
    let xdg = tmp.path().join("xdg");

    let cmd = Command::Observe(observe_args(ObserveMode::Doctor {
        json: true,
        project_dir: Some(project_dir.to_string_lossy().to_string()),
    }));

    temp_env::with_vars(
        [
            ("HOME", Some(home.to_str().unwrap())),
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
        ],
        || {
            let result = run_command(cmd);
            assert_eq!(result.unwrap(), 0);
        },
    );
}

#[test]
fn observe_doctor_reports_legacy_lifecycle_and_stale_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp.path().join("project");
    write_doctor_project(&project_dir, true);
    let home = tmp.path().join("home");
    fs::create_dir_all(home.join(".claude").join("projects")).unwrap();
    let bin_dir = home.join(".local").join("bin");
    fs::create_dir_all(&bin_dir).unwrap();
    fs::write(bin_dir.join("harness"), "").unwrap();
    let xdg = tmp.path().join("xdg");

    temp_env::with_vars(
        [
            ("HOME", Some(home.to_str().unwrap())),
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
        ],
        || {
            let pointer_path = current_run_context_path_for_project(&project_dir);
            fs::create_dir_all(pointer_path.parent().unwrap()).unwrap();
            let pointer = CurrentRunRecord {
                layout: RunLayout::from_run_dir(&tmp.path().join("runs").join("missing-run")),
                profile: Some("single-zone".into()),
                repo_root: None,
                suite_dir: None,
                suite_id: None,
                suite_path: None,
                cluster: None,
                keep_clusters: false,
                user_stories: vec![],
                requires: vec![],
            };
            fs::write(
                pointer_path,
                serde_json::to_string_pretty(&pointer).unwrap(),
            )
            .unwrap();

            let cmd = Command::Observe(observe_args(ObserveMode::Doctor {
                json: true,
                project_dir: Some(project_dir.to_string_lossy().to_string()),
            }));
            let result = run_command(cmd);
            assert_eq!(result.unwrap(), 2);
        },
    );
}

#[test]
fn scan_severity_filter_excludes_low() {
    let tmp = tempfile::tempdir().unwrap();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{
                "type": "text",
                "text": "Error: file has not been read yet. Read the file first."
            }]
        }
    });
    write_session_fixture(
        &tmp,
        "sev-filter-sess",
        &[&serde_json::to_string(&line).unwrap()],
    );

    // Tool errors are low severity - filtering for medium should exclude them
    let mut filter = default_filter();
    filter.severity = Some("medium".into());
    filter.json = true;

    let cmd = Command::Observe(observe_args(scan_mode("sev-filter-sess", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_ok());
    });
}

#[test]
fn scan_category_filter() {
    let tmp = tempfile::tempdir().unwrap();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "stop guessing and do it right!" }]
        }
    });
    write_session_fixture(
        &tmp,
        "cat-filter-sess",
        &[&serde_json::to_string(&line).unwrap()],
    );

    let mut filter = default_filter();
    filter.category = Some("build_error".into());
    filter.json = true;

    let cmd = Command::Observe(observe_args(scan_mode("cat-filter-sess", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_ok());
    });
}

#[test]
fn scan_exclude_filter() {
    let tmp = tempfile::tempdir().unwrap();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "stop guessing!" }]
        }
    });
    write_session_fixture(
        &tmp,
        "excl-filter-sess",
        &[&serde_json::to_string(&line).unwrap()],
    );

    let mut filter = default_filter();
    filter.exclude = Some("user_frustration".into());
    filter.json = true;

    let cmd = Command::Observe(observe_args(scan_mode("excl-filter-sess", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = run_command(cmd);
        assert!(result.is_ok());
    });
}

#[test]
fn scan_fixable_filter() {
    let tmp = tempfile::tempdir().unwrap();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "stop guessing!" }]
        }
    });
    write_session_fixture(
        &tmp,
        "fix-filter-sess",
        &[&serde_json::to_string(&line).unwrap()],
    );

    // User frustration is not fixable, so fixable filter should exclude it
    let mut filter = default_filter();
    filter.fixable = true;
    filter.json = true;

    let cmd = Command::Observe(observe_args(scan_mode("fix-filter-sess", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_ok());
    });
}

#[test]
fn dump_returns_ok_with_session() {
    let tmp = tempfile::tempdir().unwrap();
    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "hello world from the user" }]
        }
    });
    write_session_fixture(&tmp, "dump-sess", &[&serde_json::to_string(&line).unwrap()]);

    let cmd = Command::Observe(observe_args(ObserveMode::Dump {
        session_id: "dump-sess".into(),
        context_line: None,
        context_window: 10,
        from_line: Some(0),
        to_line: Some(10),
        filter: None,
        role: Some("user".into()),
        tool_name: None,
        raw_json: false,
        project_hint: None,
    }));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
fn context_returns_ok_with_session() {
    let tmp = tempfile::tempdir().unwrap();
    let line = serde_json::json!({
        "message": {
            "role": "assistant",
            "content": [{ "type": "text", "text": "I'll help you with that task now" }]
        }
    });
    write_session_fixture(&tmp, "ctx-sess", &[&serde_json::to_string(&line).unwrap()]);

    let cmd = Command::Observe(observe_args(ObserveMode::Dump {
        session_id: "ctx-sess".into(),
        context_line: Some(0),
        context_window: 5,
        from_line: None,
        to_line: None,
        filter: None,
        role: None,
        tool_name: None,
        raw_json: false,
        project_hint: None,
    }));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    });
}

#[test]
fn scan_output_details_written() {
    let tmp = tempfile::tempdir().unwrap();
    let details_path = tmp.path().join("details.jsonl");

    let line = serde_json::json!({
        "message": {
            "role": "user",
            "content": [{ "type": "text", "text": "stop guessing!!!!!" }]
        }
    });
    write_session_fixture(
        &tmp,
        "details-sess",
        &[&serde_json::to_string(&line).unwrap()],
    );

    let mut filter = default_filter();
    filter.json = true;
    filter.output_details = Some(details_path.to_string_lossy().to_string());

    let cmd = Command::Observe(observe_args(scan_mode("details-sess", filter)));

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_ok());
    });

    assert!(details_path.exists(), "details file should be created");
    let content = fs::read_to_string(&details_path).unwrap();
    assert!(!content.is_empty(), "details file should have content");
}
