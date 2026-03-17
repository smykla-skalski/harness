use std::fs::OpenOptions;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::context::RunLayout;
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::hook_payloads::HookContext;
use crate::io::{ensure_dir, write_text};
use crate::schema::RunStatus;
use crate::workflow::runner::{RunnerPhase, RunnerWorkflowState};

#[cfg(test)]
use std::fs;

static SANITIZE_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^A-Za-z0-9_.-]+").expect("invalid sanitize regex"));

const SUMMARY_LIMIT: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditEntry {
    pub timestamp: String,
    pub tool_name: String,
    pub tool_input: String,
    pub output_summary: String,
    pub content_hash: String,
    pub artifact_path: String,
    pub phase: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditPhaseContext {
    pub phase: String,
    pub group_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditAppendRequest {
    pub run_dir: PathBuf,
    pub tool_name: String,
    pub tool_input: String,
    pub full_output: String,
    pub phase: String,
    pub group_id: Option<String>,
}

impl AuditPhaseContext {
    #[must_use]
    pub fn new(phase: String, group_id: Option<String>) -> Self {
        Self { phase, group_id }
    }
}

/// Resolve audit phase and optional execution group from workflow state.
#[must_use]
pub fn resolve_phase_context(
    runner_state: Option<&RunnerWorkflowState>,
    run_status: Option<&RunStatus>,
    explicit_phase: Option<&str>,
    explicit_group_id: Option<&str>,
) -> AuditPhaseContext {
    let phase = explicit_phase.map_or_else(
        || {
            runner_state.map_or_else(
                || RunnerPhase::Bootstrap.to_string(),
                |state| state.phase().to_string(),
            )
        },
        str::to_string,
    );

    let group_id = if phase == RunnerPhase::Execution.to_string() {
        explicit_group_id
            .map(str::to_string)
            .or_else(|| run_status.and_then(|status| status.next_planned_group.clone()))
            .or_else(|| run_status.and_then(|status| status.last_completed_group.clone()))
    } else {
        None
    };

    AuditPhaseContext::new(phase, group_id)
}

/// Append one structured audit entry and write the full output artifact.
///
/// # Errors
/// Returns `CliError` when the artifact or log file cannot be written.
pub fn append_audit_entry(request: AuditAppendRequest) -> Result<AuditEntry, CliError> {
    let layout = RunLayout::from_run_dir(&request.run_dir);
    ensure_dir(&layout.audit_artifacts_dir())
        .map_err(|error| CliErrorKind::io(cow!("create audit artifacts dir: {error}")))?;

    let timestamp = utc_now();
    let content_hash = hash_text(&request.full_output);
    let artifact_path = unique_artifact_path(&layout, &timestamp, &request.tool_name);
    write_text(&artifact_path, &request.full_output)?;

    let artifact_path = relativize_path(&artifact_path, &request.run_dir);
    let entry = AuditEntry {
        timestamp,
        tool_name: request.tool_name,
        tool_input: request.tool_input,
        output_summary: truncate_summary(&request.full_output),
        content_hash,
        artifact_path,
        phase: request.phase,
        group_id: request.group_id,
    };

    let line = serde_json::to_string(&entry)
        .map_err(|error| CliErrorKind::serialize(cow!("audit entry: {error}")))?;
    append_jsonl_line(&layout.audit_log_path(), &line)?;
    Ok(entry)
}

/// Write `run-status.json` and append a matching audit entry.
///
/// # Errors
/// Returns `CliError` on write or audit failure.
pub fn write_run_status_with_audit(
    run_dir: &Path,
    status: &RunStatus,
    runner_state: Option<&RunnerWorkflowState>,
    explicit_phase: Option<&str>,
    explicit_group_id: Option<&str>,
) -> Result<(), CliError> {
    let layout = RunLayout::from_run_dir(run_dir);
    let serialized = serialize_json(status, "run status")?;
    let content = format!("{serialized}\n");
    status.save(&layout.status_path())?;

    let phase_context = resolve_phase_context(
        runner_state,
        Some(status),
        explicit_phase,
        explicit_group_id,
    );
    append_audit_entry(AuditAppendRequest {
        run_dir: run_dir.to_path_buf(),
        tool_name: "RunStatusWrite".to_string(),
        tool_input: "run-status.json".to_string(),
        full_output: content,
        phase: phase_context.phase,
        group_id: phase_context.group_id,
    })?;
    Ok(())
}

/// Append an audit entry after `suite-run-state.json` is written.
///
/// # Errors
/// Returns `CliError` on serialization or audit failure.
pub fn append_runner_state_audit(
    run_dir: &Path,
    state: &RunnerWorkflowState,
) -> Result<(), CliError> {
    let serialized = serialize_json(state, "runner state")?;
    let phase_name = state.phase().to_string();
    let run_status = load_run_status(run_dir)?;
    let phase_context =
        resolve_phase_context(Some(state), run_status.as_ref(), Some(&phase_name), None);
    append_audit_entry(AuditAppendRequest {
        run_dir: run_dir.to_path_buf(),
        tool_name: "RunnerStateWrite".to_string(),
        tool_input: "suite-run-state.json".to_string(),
        full_output: format!("{serialized}\n"),
        phase: phase_context.phase,
        group_id: phase_context.group_id,
    })?;
    Ok(())
}

/// Build an audit append request from a hook context.
///
/// # Errors
/// Returns `CliError` when the hook does not have an active run directory.
pub fn build_hook_audit_request(ctx: &HookContext) -> Result<AuditAppendRequest, CliError> {
    let run_dir = ctx
        .effective_run_dir()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("run_dir"))?;
    let phase_context = resolve_phase_context(
        ctx.runner_state.as_ref(),
        ctx.run.as_ref().and_then(|run| run.status.as_ref()),
        None,
        hook_group_id(ctx).as_deref(),
    );

    Ok(AuditAppendRequest {
        run_dir: run_dir.into_owned(),
        tool_name: ctx.tool_name().to_string(),
        tool_input: summarize_tool_input(ctx.tool_name(), ctx.tool_input()),
        full_output: normalize_tool_output(ctx.tool_name(), ctx.tool_response()),
        phase: phase_context.phase,
        group_id: phase_context.group_id,
    })
}

/// Summarize the tool input in a stable audit-friendly form.
#[must_use]
pub fn summarize_tool_input(tool_name: &str, tool_input: &Value) -> String {
    match tool_name {
        "Bash" => string_field(tool_input, "command"),
        "Read" | "Write" | "Edit" => summarize_file_paths(tool_input),
        "Glob" => string_field(tool_input, "pattern"),
        "Agent" => first_non_empty_string(
            tool_input,
            &["description", "prompt", "task", "message", "goal"],
        ),
        "AskUserQuestion" => summarize_questions(tool_input),
        _ => normalize_json_value(tool_input),
    }
}

/// Normalize the full tool output that is written to the audit artifact.
#[must_use]
pub fn normalize_tool_output(tool_name: &str, tool_response: &Value) -> String {
    match tool_name {
        "Bash" => {
            let stdout = string_field(tool_response, "stdout");
            let stderr = string_field(tool_response, "stderr");
            let exit_code = tool_response
                .get("exit_code")
                .or_else(|| tool_response.get("exitCode"))
                .and_then(Value::as_i64)
                .unwrap_or_default();
            format!("exit code: {exit_code}\n--- STDOUT ---\n{stdout}\n--- STDERR ---\n{stderr}")
        }
        "AskUserQuestion" => summarize_answers(tool_response),
        _ => normalize_json_value(tool_response),
    }
}

#[must_use]
fn hook_group_id(ctx: &HookContext) -> Option<String> {
    if ctx.runner_state.as_ref().map(RunnerWorkflowState::phase) != Some(RunnerPhase::Execution) {
        return None;
    }

    if let Some(gid) = ctx.parsed_command().ok().flatten().and_then(|command| {
        command
            .first_harness_invocation()
            .and_then(|invocation| invocation.gid().map(str::to_string))
    }) {
        return Some(gid);
    }

    ctx.run
        .as_ref()
        .and_then(|run| run.status.as_ref())
        .and_then(|status| status.next_planned_group.clone())
}

fn summarize_file_paths(tool_input: &Value) -> String {
    let mut paths = Vec::new();
    if let Some(path) = tool_input.get("file_path").and_then(Value::as_str) {
        paths.push(path.to_string());
    }
    if let Some(values) = tool_input.get("file_paths").and_then(Value::as_array) {
        paths.extend(values.iter().filter_map(Value::as_str).map(str::to_string));
    }
    if paths.is_empty() {
        normalize_json_value(tool_input)
    } else {
        paths.join(", ")
    }
}

fn summarize_questions(tool_input: &Value) -> String {
    let Some(questions) = tool_input.get("questions").and_then(Value::as_array) else {
        return normalize_json_value(tool_input);
    };
    let prompts = questions
        .iter()
        .filter_map(|question| question.get("question").and_then(Value::as_str))
        .map(question_head)
        .filter(|question| !question.is_empty())
        .collect::<Vec<_>>();
    if prompts.is_empty() {
        normalize_json_value(tool_input)
    } else {
        prompts.join(" | ")
    }
}

fn summarize_answers(tool_response: &Value) -> String {
    let Some(answers) = tool_response.get("answers").and_then(Value::as_array) else {
        return normalize_json_value(tool_response);
    };
    let rendered = answers
        .iter()
        .filter_map(|answer| {
            let question = answer.get("question").and_then(Value::as_str)?;
            let value = answer.get("answer").and_then(Value::as_str)?;
            Some(format!("{} => {value}", question_head(question)))
        })
        .collect::<Vec<_>>();
    if rendered.is_empty() {
        normalize_json_value(tool_response)
    } else {
        rendered.join("\n")
    }
}

fn question_head(question: &str) -> &str {
    question.lines().next().unwrap_or(question).trim()
}

fn string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn first_non_empty_string(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        let field = string_field(value, key);
        if !field.is_empty() {
            return field;
        }
    }
    normalize_json_value(value)
}

fn normalize_json_value(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
    }
}

fn truncate_summary(text: &str) -> String {
    if text.len() <= SUMMARY_LIMIT {
        return text.to_string();
    }
    text[..text.floor_char_boundary(SUMMARY_LIMIT)].to_string()
}

fn hash_text(text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    hex::encode(hasher.finalize())
}

fn load_run_status(run_dir: &Path) -> Result<Option<RunStatus>, CliError> {
    let path = RunLayout::from_run_dir(run_dir).status_path();
    if !path.exists() {
        return Ok(None);
    }
    RunStatus::load(&path).map(Some)
}

fn serialize_json<T>(value: &T, label: &str) -> Result<String, CliError>
where
    T: Serialize,
{
    serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::serialize(cow!("{label}: {error}")).into())
}

fn unique_artifact_path(layout: &RunLayout, timestamp: &str, tool_name: &str) -> PathBuf {
    let sanitized_tool_name = sanitize_tool_name(tool_name);
    let base_name = format!("{}-{sanitized_tool_name}", artifact_timestamp(timestamp));
    let mut candidate = layout
        .audit_artifacts_dir()
        .join(format!("{base_name}.txt"));
    let mut suffix = 1_u32;
    while candidate.exists() {
        candidate = layout
            .audit_artifacts_dir()
            .join(format!("{base_name}-{suffix}.txt"));
        suffix += 1;
    }
    candidate
}

fn sanitize_tool_name(tool_name: &str) -> String {
    let sanitized = SANITIZE_NAME_RE
        .replace_all(tool_name, "-")
        .trim_matches('-')
        .to_string();
    if sanitized.is_empty() {
        "tool".to_string()
    } else {
        sanitized
    }
}

fn artifact_timestamp(timestamp: &str) -> String {
    timestamp.replace(['-', ':'], "")
}

fn relativize_path(path: &Path, run_dir: &Path) -> String {
    path.strip_prefix(run_dir).map_or_else(
        |_| path.display().to_string(),
        |relative| relative.display().to_string(),
    )
}

fn append_jsonl_line(path: &Path, line: &str) -> Result<(), CliError> {
    let parent = path
        .parent()
        .ok_or_else(|| CliErrorKind::io(cow!("missing parent directory for {}", path.display())))?;
    ensure_dir(parent)
        .map_err(|error| CliErrorKind::io(cow!("create dir {}: {error}", parent.display())))?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| CliErrorKind::io(cow!("open {}: {error}", path.display())))?;
    writeln!(file, "{line}")
        .map_err(|error| CliErrorKind::io(cow!("append {}: {error}", path.display())).into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{RunCounts, Verdict};
    use crate::workflow::runner::{PreflightState, PreflightStatus};

    fn sample_status(run_id: &str, suite_id: &str) -> RunStatus {
        RunStatus {
            run_id: run_id.to_string(),
            suite_id: suite_id.to_string(),
            profile: "single-zone".to_string(),
            started_at: String::new(),
            overall_verdict: Verdict::Pending,
            completed_at: None,
            counts: RunCounts::default(),
            executed_groups: vec![],
            skipped_groups: vec![],
            last_completed_group: None,
            last_state_capture: None,
            last_updated_utc: None,
            next_planned_group: None,
            notes: vec![],
        }
    }

    #[test]
    fn resolve_phase_context_keeps_group_only_for_execution() {
        let state = RunnerWorkflowState {
            schema_version: 1,
            phase: RunnerPhase::Execution,
            preflight: PreflightState {
                status: PreflightStatus::Complete,
            },
            failure: None,
            suite_fix: None,
            updated_at: String::new(),
            transition_count: 0,
            last_event: None,
        };
        let mut status = sample_status("r1", "s1");
        status.next_planned_group = Some("g03".to_string());

        let context = resolve_phase_context(Some(&state), Some(&status), None, None);
        assert_eq!(context.phase, "execution");
        assert_eq!(context.group_id.as_deref(), Some("g03"));

        let context = resolve_phase_context(Some(&state), Some(&status), Some("closeout"), None);
        assert_eq!(context.phase, "closeout");
        assert!(context.group_id.is_none());
    }

    #[test]
    fn normalize_tool_output_formats_bash() {
        let output = normalize_tool_output(
            "Bash",
            &serde_json::json!({
                "stdout": "ok",
                "stderr": "warn",
                "exit_code": 7,
            }),
        );
        assert_eq!(
            output,
            "exit code: 7\n--- STDOUT ---\nok\n--- STDERR ---\nwarn"
        );
    }

    #[test]
    #[allow(clippy::cognitive_complexity)]
    fn append_audit_entry_writes_jsonl_and_artifact() {
        let tempdir = tempfile::tempdir().unwrap();
        let run_dir = tempdir.path().join("r01");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();

        let entry = append_audit_entry(AuditAppendRequest {
            run_dir: run_dir.clone(),
            tool_name: "Read".to_string(),
            tool_input: "suite.md".to_string(),
            full_output: "file contents".to_string(),
            phase: "execution".to_string(),
            group_id: Some("g01".to_string()),
        })
        .unwrap();

        assert_eq!(entry.tool_name, "Read");
        assert_eq!(entry.tool_input, "suite.md");
        assert_eq!(entry.output_summary, "file contents");
        assert_eq!(entry.group_id.as_deref(), Some("g01"));
        assert!(run_dir.join(&entry.artifact_path).exists());

        let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
        assert!(log_contents.contains("\"tool_name\":\"Read\""));
        assert!(log_contents.contains("\"group_id\":\"g01\""));
    }

    #[test]
    fn write_run_status_with_audit_records_status_write() {
        let tempdir = tempfile::tempdir().unwrap();
        let run_dir = tempdir.path().join("r01");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();

        let status = sample_status("r01", "suite");

        write_run_status_with_audit(&run_dir, &status, None, Some("bootstrap"), None).unwrap();

        let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
        assert!(log_contents.contains("\"tool_name\":\"RunStatusWrite\""));
        assert!(log_contents.contains("\"phase\":\"bootstrap\""));
        assert!(layout.status_path().exists());
    }

    #[test]
    fn append_runner_state_audit_records_runner_state_write() {
        let tempdir = tempfile::tempdir().unwrap();
        let run_dir = tempdir.path().join("r01");
        let layout = RunLayout::from_run_dir(&run_dir);
        layout.ensure_dirs().unwrap();

        let mut status = sample_status("r01", "suite");
        status.last_completed_group = Some("g02".to_string());
        status.next_planned_group = Some("g03".to_string());
        write_run_status_with_audit(&run_dir, &status, None, Some("execution"), Some("g03"))
            .unwrap();

        let state = RunnerWorkflowState {
            schema_version: 1,
            phase: RunnerPhase::Execution,
            preflight: PreflightState {
                status: PreflightStatus::Complete,
            },
            failure: None,
            suite_fix: None,
            updated_at: String::new(),
            transition_count: 0,
            last_event: None,
        };

        append_runner_state_audit(&run_dir, &state).unwrap();

        let log_contents = fs::read_to_string(layout.audit_log_path()).unwrap();
        assert!(log_contents.contains("\"tool_name\":\"RunnerStateWrite\""));
        assert!(log_contents.contains("\"group_id\":\"g03\""));
    }

    #[test]
    fn summarize_tool_input_handles_questions() {
        let summary = summarize_tool_input(
            "AskUserQuestion",
            &serde_json::json!({
                "questions": [
                    {"question": "Proceed?\nMore detail", "options": []}
                ]
            }),
        );
        assert_eq!(summary, "Proceed?");
    }

    #[test]
    fn summarize_answers_prefers_question_answer_lines() {
        let summary = summarize_answers(&serde_json::json!({
            "answers": [
                {"question": "Proceed?\nMore detail", "answer": "Yes"}
            ]
        }));
        assert_eq!(summary, "Proceed? => Yes");
    }
}
