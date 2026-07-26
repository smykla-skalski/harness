use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use sha2::{Digest, Sha256};

use harness_kernel::errors::{CliError, CliErrorKind, io_for};
use harness_kernel::redact::secrets;

use crate::hooks::application::GuardContext as HookContext;
use crate::infra::io::{ensure_dir, write_text};
use crate::run::context::RunLayout;
use crate::workspace::utc_now;

use super::summarize::{normalize_tool_output, summarize_tool_input};
use super::types::{AuditAppendRequest, AuditEntry};

static SANITIZE_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^A-Za-z0-9_.-]+").expect("invalid sanitize regex"));

const SUMMARY_LIMIT: usize = 500;

/// Phase recorded on every hook audit entry. The retired suite workflow could
/// report other phases, but outside a suite run it always resolved to this one,
/// and the audit log schema still carries the field.
const HOOK_AUDIT_PHASE: &str = "bootstrap";

/// Append one structured audit entry and write the full output artifact.
///
/// # Errors
/// Returns `CliError` when the artifact or log file cannot be written.
pub fn append_audit_entry(request: AuditAppendRequest) -> Result<AuditEntry, CliError> {
    let layout = RunLayout::from_run_dir(&request.run_dir);
    ensure_dir(&layout.audit_artifacts_dir())
        .map_err(|error| CliErrorKind::io(format!("create audit artifacts dir: {error}")))?;

    let timestamp = utc_now();
    let scrubbed_output = secrets(&request.full_output);
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

/// Build an audit append request from a hook context.
///
/// # Errors
/// Returns `CliError` when the hook does not have an active run directory.
pub fn build_hook_audit_request(ctx: &HookContext) -> Result<AuditAppendRequest, CliError> {
    let run_dir = ctx
        .effective_run_dir()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("run_dir"))?;

    Ok(AuditAppendRequest {
        run_dir: run_dir.into_owned(),
        tool_name: ctx.tool_name().to_string(),
        tool_input: summarize_tool_input(ctx.tool_name(), ctx.tool_input()),
        full_output: normalize_tool_output(ctx.tool_name(), ctx.tool_response()),
        phase: HOOK_AUDIT_PHASE.to_string(),
        group_id: None,
    })
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
