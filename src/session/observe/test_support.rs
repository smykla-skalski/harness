use std::io::Write;
use std::path::Path;

use fs_err as fs;
use harness_testkit::with_isolated_harness_env;

use crate::agents::runtime;
use crate::hooks::adapters::HookAgent;
use crate::observe::types::{
    Confidence, FixSafety, Issue, IssueCategory, IssueCode, IssueSeverity, MessageRole,
};
use crate::workspace::project_context_dir;

pub(super) fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
            let project = tmp.path().join("project");
            fs::create_dir_all(&project).expect("create project dir");
            test_fn(&project);
        });
    });
}

pub(super) fn write_agent_log_lines(
    project_dir: &Path,
    runtime: HookAgent,
    session_id: &str,
    lines: &[serde_json::Value],
) {
    let log_path = project_context_dir(project_dir)
        .join("agents/sessions")
        .join(runtime::runtime_for(runtime).name())
        .join(session_id)
        .join("raw.jsonl");
    fs::create_dir_all(
        log_path
            .parent()
            .expect("raw agent log should always have a parent"),
    )
    .expect("create agent log directory");
    let content = lines
        .iter()
        .map(serde_json::Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(&log_path, content).expect("write agent log");
}

pub(super) fn write_agent_log(
    project_dir: &Path,
    runtime: HookAgent,
    session_id: &str,
    text: &str,
) {
    write_agent_log_lines(
        project_dir,
        runtime,
        session_id,
        &[serde_json::json!({
            "timestamp": "2026-03-28T12:00:00Z",
            "message": {
                "role": "assistant",
                "content": text,
            }
        })],
    );
}

pub(super) fn append_agent_log_lines(
    project_dir: &Path,
    runtime: HookAgent,
    session_id: &str,
    lines: &[serde_json::Value],
) {
    let log_path = project_context_dir(project_dir)
        .join("agents/sessions")
        .join(runtime::runtime_for(runtime).name())
        .join(session_id)
        .join("raw.jsonl");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .expect("open agent log for append");
    let content = lines
        .iter()
        .map(serde_json::Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    file.write_all(content.as_bytes())
        .expect("append agent log lines");
}

pub(super) fn infrastructure_issue(fingerprint: &str) -> Issue {
    Issue {
        id: format!("issue-{fingerprint}"),
        line: 10,
        code: IssueCode::HarnessInfrastructureMisconfiguration,
        category: IssueCategory::WorkflowError,
        severity: IssueSeverity::Critical,
        confidence: Confidence::High,
        fix_safety: FixSafety::TriageRequired,
        summary: "Harness infrastructure misconfiguration detected".to_string(),
        details: "Observe found a runtime/session transcript issue".to_string(),
        fingerprint: fingerprint.to_string(),
        source_role: MessageRole::Assistant,
        source_tool: None,
        fix_target: Some("skills/observe/SKILL.md".to_string()),
        fix_hint: None,
        evidence_excerpt: Some("This is a harness infrastructure issue".to_string()),
    }
}
