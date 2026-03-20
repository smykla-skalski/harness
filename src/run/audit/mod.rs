mod scrub;
mod summarize;
mod types;

pub use summarize::{normalize_tool_output, summarize_tool_input};
pub use types::{AuditAppendRequest, AuditEntry, AuditPhaseContext};

use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::errors::{CliError, CliErrorKind, io_for};
use crate::hooks::application::GuardContext as HookContext;
use crate::infra::io::{ensure_dir, write_text};
use crate::run::RunStatus;
use crate::run::context::RunLayout;
use crate::run::workflow::{RunnerPhase, RunnerWorkflowState};
use crate::workspace::utc_now;

static SANITIZE_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^A-Za-z0-9_.-]+").expect("invalid sanitize regex"));

const SUMMARY_LIMIT: usize = 500;

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
        .map_err(|error| CliErrorKind::io(format!("create audit artifacts dir: {error}")))?;

    let timestamp = utc_now();
    let scrubbed_output = scrub::scrub(&request.full_output);
    let content_hash = hash_text(&scrubbed_output);
    let artifact_path = unique_artifact_path(&layout, &timestamp, &request.tool_name);
    write_text(&artifact_path, &scrubbed_output)?;

    let artifact_path = relativize_path(&artifact_path, &request.run_dir);
    let entry = AuditEntry {
        timestamp,
        tool_name: request.tool_name,
        tool_input: request.tool_input,
        output_summary: truncate_summary(&scrubbed_output),
        content_hash,
        artifact_path,
        phase: request.phase,
        group_id: request.group_id,
    };

    let line = serde_json::to_string(&entry)
        .map_err(|error| CliErrorKind::serialize(format!("audit entry: {error}")))?;
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
        .map_err(|error| CliErrorKind::serialize(format!("{label}: {error}")).into())
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
    let parent = path.parent().ok_or_else(|| {
        CliErrorKind::io(format!("missing parent directory for {}", path.display()))
    })?;
    ensure_dir(parent).map_err(|error| io_for("create dir", parent, &error))?;
    let is_new = !path.exists();
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| io_for("open", path, &error))?;
    writeln!(file, "{line}").map_err(|error| io_for("append", path, &error))?;

    #[cfg(unix)]
    if is_new {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|e| io_for("set permissions", path, &e))?;
    }

    Ok(())
}

#[cfg(test)]
mod tests;
