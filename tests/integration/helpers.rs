// Shared test helper utilities for integration tests.
// Provides suite/group file writers, run initialization, hook payload builders,
// kubectl-validate state seeding, and assertion helpers.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use harness::context::{RunLayout, RunMetadata};
use harness::hook::{Decision, HookResult};
use harness::hook_payloads::{
    AskUserQuestionOption, AskUserQuestionPrompt, HookContext, HookEnvelopePayload,
    HookMessagePayload, HookWriteRequest,
};
use harness::schema::{RunCounts, RunStatus};
use harness::workflow::runner::{self as runner_workflow, RunnerWorkflowState};

// ---------------------------------------------------------------------------
// Suite and group file writers
// ---------------------------------------------------------------------------

pub fn write_suite(path: &Path) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create suite parent dirs");
    }
    fs::write(
        path,
        "\
---
suite_id: example.suite
feature: example
scope: unit
profiles: [single-zone]
required_dependencies: []
user_stories: []
variant_decisions: []
coverage_expectations: [configure, consume, debug]
baseline_files: []
groups: [groups/g01.md]
skipped_groups: []
keep_clusters: false
---

# Test suite
",
    )
    .expect("write suite file");
}

pub fn write_group(path: &Path) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create group parent dirs");
    }
    fs::write(
        path,
        "\
---
group_id: g01
story: example story
capability: example capability
profiles: [single-zone]
preconditions: []
success_criteria: []
debug_checks: []
artifacts: []
variant_source: base
helm_values: {}
restart_namespaces: []
---

## Configure

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: example
```

## Consume

- Nothing to execute.

## Debug

- Nothing to inspect.
",
    )
    .expect("write group file");
}

pub fn write_meshmetric_group(path: &Path, invalid_open_telemetry_backend_ref: bool) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create group parent dirs");
    }
    let backend_ref = if invalid_open_telemetry_backend_ref {
        "\
          backendRef:
            kind: MeshService
            name: otel-collector
"
    } else {
        ""
    };
    let content = format!(
        "\
---
group_id: g01
story: meshmetric example story
capability: meshmetric example capability
profiles: [single-zone]
preconditions: []
success_criteria: []
debug_checks: []
artifacts: []
variant_source: base
helm_values: {{}}
restart_namespaces: []
---

## Configure

```yaml
apiVersion: kuma.io/v1alpha1
kind: MeshMetric
metadata:
  name: demo-metrics
  namespace: kuma-system
  labels:
    kuma.io/mesh: default
spec:
  targetRef:
    kind: Mesh
  default:
    backends:
      - type: OpenTelemetry
        openTelemetry:
          endpoint: otel-collector.observability.svc:4317
{backend_ref}```

## Consume

- Nothing to execute.

## Debug

- Nothing to inspect.
"
    );
    fs::write(path, content).expect("write meshmetric group file");
}

// ---------------------------------------------------------------------------
// Run initialization
// ---------------------------------------------------------------------------

/// Initialize a complete run directory with metadata, status, and runner state.
/// Returns the path to the run directory.
pub fn init_run(tmp_path: &Path, run_id: &str, profile: &str) -> PathBuf {
    let suite_dir = tmp_path.join("suite");
    write_suite(&suite_dir.join("suite.md"));
    write_group(&suite_dir.join("groups").join("g01.md"));

    let run_root = tmp_path.join("runs");
    let layout = RunLayout {
        run_root: run_root.to_string_lossy().to_string(),
        run_id: run_id.to_string(),
    };
    layout.ensure_dirs().expect("create run dirs");

    let suite_path = suite_dir.join("suite.md");
    let metadata = RunMetadata {
        run_id: run_id.to_string(),
        suite_id: "example.suite".to_string(),
        suite_path: suite_path.to_string_lossy().to_string(),
        suite_dir: suite_dir.to_string_lossy().to_string(),
        profile: profile.to_string(),
        repo_root: tmp_path.to_string_lossy().to_string(),
        keep_clusters: false,
        created_at: "2026-03-14T00:00:00Z".to_string(),
        user_stories: vec![],
        required_dependencies: vec![],
    };
    let meta_json = serde_json::to_string_pretty(&metadata).expect("serialize metadata");
    fs::write(layout.metadata_path(), format!("{meta_json}\n")).expect("write metadata");

    let status = RunStatus {
        run_id: run_id.to_string(),
        suite_id: "example.suite".to_string(),
        profile: profile.to_string(),
        started_at: "2026-03-14T00:00:00Z".to_string(),
        overall_verdict: "pending".to_string(),
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    };
    let status_json = serde_json::to_string_pretty(&status).expect("serialize status");
    fs::write(layout.status_path(), format!("{status_json}\n")).expect("write status");

    runner_workflow::initialize_runner_state(&layout.run_dir()).expect("initialize runner state");

    layout.run_dir()
}

/// Initialize a run and return `(run_dir, suite_dir)` for tests that need both.
pub fn init_run_with_suite(tmp_path: &Path, run_id: &str, profile: &str) -> (PathBuf, PathBuf) {
    let run_dir = init_run(tmp_path, run_id, profile);
    let suite_dir = tmp_path.join("suite");
    (run_dir, suite_dir)
}

// ---------------------------------------------------------------------------
// Hook payload builders
// ---------------------------------------------------------------------------

pub fn make_bash_payload(command: &str) -> HookEnvelopePayload {
    HookEnvelopePayload {
        root: None,
        input_payload: Some(HookMessagePayload {
            command: Some(command.to_string()),
            file_path: None,
            writes: vec![],
            questions: vec![],
            answers: vec![],
            annotations: vec![],
        }),
        tool_input: None,
        response: None,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    }
}

pub fn make_write_payload(file_path: &str) -> HookEnvelopePayload {
    HookEnvelopePayload {
        root: None,
        input_payload: Some(HookMessagePayload {
            command: None,
            file_path: Some(file_path.to_string()),
            writes: vec![],
            questions: vec![],
            answers: vec![],
            annotations: vec![],
        }),
        tool_input: None,
        response: None,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    }
}

pub fn make_multi_write_payload(paths: &[&str]) -> HookEnvelopePayload {
    let writes = paths
        .iter()
        .map(|p| HookWriteRequest {
            file_path: p.to_string(),
        })
        .collect();
    HookEnvelopePayload {
        root: None,
        input_payload: Some(HookMessagePayload {
            command: None,
            file_path: None,
            writes,
            questions: vec![],
            answers: vec![],
            annotations: vec![],
        }),
        tool_input: None,
        response: None,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    }
}

pub fn make_stop_payload() -> HookEnvelopePayload {
    HookEnvelopePayload {
        root: None,
        input_payload: None,
        tool_input: None,
        response: None,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: true,
        raw_keys: vec![],
    }
}

pub fn make_question_payload(question: &str, options: &[&str]) -> HookEnvelopePayload {
    let prompt = AskUserQuestionPrompt {
        question: question.to_string(),
        header: Some("Approval".to_string()),
        options: options
            .iter()
            .map(|label| AskUserQuestionOption {
                label: label.to_string(),
                description: format!("Select {label}"),
            })
            .collect(),
        multi_select: false,
    };
    HookEnvelopePayload {
        root: None,
        input_payload: Some(HookMessagePayload {
            command: None,
            file_path: None,
            writes: vec![],
            questions: vec![prompt],
            answers: vec![],
            annotations: vec![],
        }),
        tool_input: None,
        response: None,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    }
}

pub fn make_question_answer_payload(
    question: &str,
    options: &[&str],
    answer: &str,
) -> HookEnvelopePayload {
    let prompt = AskUserQuestionPrompt {
        question: question.to_string(),
        header: Some("Approval".to_string()),
        options: options
            .iter()
            .map(|label| AskUserQuestionOption {
                label: label.to_string(),
                description: format!("Select {label}"),
            })
            .collect(),
        multi_select: false,
    };
    HookEnvelopePayload {
        root: None,
        input_payload: Some(HookMessagePayload {
            command: None,
            file_path: None,
            writes: vec![],
            questions: vec![prompt.clone()],
            answers: vec![],
            annotations: vec![],
        }),
        tool_input: None,
        response: Some(serde_json::json!({
            "questions": [serde_json::to_value(&prompt).unwrap()],
            "answers": [{"question": question, "answer": answer}],
        })),
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    }
}

pub fn make_empty_payload() -> HookEnvelopePayload {
    HookEnvelopePayload {
        root: None,
        input_payload: None,
        tool_input: None,
        response: None,
        last_assistant_message: None,
        transcript_path: None,
        stop_hook_active: false,
        raw_keys: vec![],
    }
}

/// Build a `HookContext` for a given skill and envelope.
pub fn make_hook_context(skill: &str, payload: HookEnvelopePayload) -> HookContext {
    HookContext::from_envelope(skill, payload)
}

/// Build a `HookContext` with an associated run directory.
pub fn make_hook_context_with_run(
    skill: &str,
    payload: HookEnvelopePayload,
    run_dir: &Path,
) -> HookContext {
    use harness::context::RunContext;

    let mut ctx = HookContext::from_envelope(skill, payload);
    ctx.run_dir = Some(run_dir.to_path_buf());
    // Reload context from disk now that run_dir is set.
    if let Ok(run_ctx) = RunContext::from_run_dir(run_dir) {
        ctx.runner_state = runner_workflow::read_runner_state(&run_ctx.layout.run_dir())
            .ok()
            .flatten();
        ctx.run = Some(run_ctx);
    }
    ctx
}

// ---------------------------------------------------------------------------
// kubectl-validate state seeding
// ---------------------------------------------------------------------------

pub fn seed_kubectl_validate_state(
    xdg_data_home: &Path,
    decision: &str,
    binary_path: Option<&Path>,
) {
    let path = xdg_data_home
        .join("kuma")
        .join("tooling")
        .join("kubectl-validate.json");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create tooling dir");
    }
    let mut payload = serde_json::json!({
        "schema_version": 1,
        "decision": decision,
        "decided_at": "2026-03-13T00:00:00Z",
    });
    if let Some(bp) = binary_path {
        payload["binary_path"] = serde_json::Value::String(bp.to_string_lossy().to_string());
    }
    fs::write(&path, serde_json::to_string(&payload).unwrap())
        .expect("write kubectl-validate state");
}

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

pub fn assert_decision(result: &HookResult, expected: &Decision) {
    assert_eq!(
        &result.decision, expected,
        "expected {expected:?}, got {:?} (code={}, message={})",
        result.decision, result.code, result.message
    );
}

pub fn assert_allow(result: &HookResult) {
    assert_decision(result, &Decision::Allow);
}

pub fn assert_deny(result: &HookResult) {
    assert_decision(result, &Decision::Deny);
}

pub fn assert_warn(result: &HookResult) {
    assert_decision(result, &Decision::Warn);
}

// ---------------------------------------------------------------------------
// Run status helpers
// ---------------------------------------------------------------------------

pub fn read_run_status(run_dir: &Path) -> RunStatus {
    let path = run_dir.join("run-status.json");
    let text = fs::read_to_string(&path).expect("read run-status.json");
    serde_json::from_str(&text).expect("parse run-status.json")
}

pub fn write_run_status(run_dir: &Path, status: &RunStatus) {
    let path = run_dir.join("run-status.json");
    let json = serde_json::to_string_pretty(status).expect("serialize status");
    fs::write(&path, format!("{json}\n")).expect("write run-status.json");
}

pub fn read_runner_state(run_dir: &Path) -> Option<RunnerWorkflowState> {
    runner_workflow::read_runner_state(run_dir).expect("read runner state")
}
