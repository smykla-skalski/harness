// Integration tests for the `harness observe` command.
// Tests error paths and basic scan behavior with synthetic JSONL fixtures.

use std::io::Write;

use harness::cli::{Command, ObserveFilterArgs, ObserveMode};
use harness::commands::Execute;

fn default_filter() -> ObserveFilterArgs {
    ObserveFilterArgs {
        from_line: 0,
        project_hint: None,
        json: false,
        summary: false,
        severity: None,
        category: None,
        exclude: None,
        fixable: false,
        output: None,
        output_details: None,
    }
}

#[test]
fn scan_missing_session_returns_error() {
    let tmp = tempfile::tempdir().unwrap();
    let mut filter = default_filter();
    filter.project_hint = Some("nonexistent".into());

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "does-not-exist-ever".into(),
            filter,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI080");
    });
}

#[test]
fn dump_missing_session_returns_error() {
    let tmp = tempfile::tempdir().unwrap();

    let cmd = Command::Observe {
        mode: ObserveMode::Dump {
            session_id: "no-such-session".into(),
            from_line: None,
            to_line: None,
            filter: None,
            role: None,
            project_hint: None,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI080");
    });
}

#[test]
fn context_missing_session_returns_error() {
    let tmp = tempfile::tempdir().unwrap();

    let cmd = Command::Observe {
        mode: ObserveMode::Context {
            session_id: "no-such-session".into(),
            line: 10,
            window: 5,
            project_hint: None,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_err());
    });
}

fn write_session_fixture(tmp: &tempfile::TempDir, session_id: &str, lines: &[&str]) {
    let project_dir = tmp
        .path()
        .join(".claude")
        .join("projects")
        .join("test-project");
    std::fs::create_dir_all(&project_dir).unwrap();
    let session_file = project_dir.join(format!("{session_id}.jsonl"));
    let mut file = std::fs::File::create(session_file).unwrap();
    for line in lines {
        writeln!(file, "{line}").unwrap();
    }
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

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "build-err-sess".into(),
            filter,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    });
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

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "sev-filter-sess".into(),
            filter,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
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

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "cat-filter-sess".into(),
            filter,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
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

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "excl-filter-sess".into(),
            filter,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
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

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "fix-filter-sess".into(),
            filter,
        },
    };

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

    let cmd = Command::Observe {
        mode: ObserveMode::Dump {
            session_id: "dump-sess".into(),
            from_line: Some(0),
            to_line: Some(10),
            filter: None,
            role: Some("user".into()),
            project_hint: None,
        },
    };

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

    let cmd = Command::Observe {
        mode: ObserveMode::Context {
            session_id: "ctx-sess".into(),
            line: 0,
            window: 5,
            project_hint: None,
        },
    };

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

    let cmd = Command::Observe {
        mode: ObserveMode::Scan {
            session_id: "details-sess".into(),
            filter,
        },
    };

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = cmd.execute();
        assert!(result.is_ok());
    });

    assert!(details_path.exists(), "details file should be created");
    let content = std::fs::read_to_string(&details_path).unwrap();
    assert!(!content.is_empty(), "details file should have content");
}
