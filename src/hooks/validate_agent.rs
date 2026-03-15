use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;
use crate::workflow::runner::{self as runner_wf, PreflightStatus, RunnerPhase};

static CODE_BLOCK_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)```.*?```").unwrap());

static PREFLIGHT_RE: LazyLock<Regex> = LazyLock::new(|| {
    let head = runner_rules::PREFLIGHT_REPLY_HEAD;
    let pass = runner_rules::PREFLIGHT_REPLY_PASS;
    let fail = runner_rules::PREFLIGHT_REPLY_FAIL;
    let pattern = format!(r"^{}\s*({pass}|{fail})$", regex::escape(head));
    Regex::new(&pattern).unwrap()
});

const REQUIRED_READER_SECTIONS: &[&str] = &["saved"];
const CODE_BLOCK_LINE_LIMIT: usize = 60;

/// Execute the validate-agent hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_author() {
        return Ok(validate_suite_author(ctx));
    }
    Ok(validate_suite_runner(ctx))
}

fn validate_suite_author(ctx: &HookContext) -> HookResult {
    if ctx.stop_hook_active() {
        return HookResult::allow();
    }
    let message = ctx.last_assistant_message().to_lowercase();
    if message.is_empty() {
        return HookResult::allow();
    }
    let stripped = message.trim_end_matches('.');
    let missing: Vec<&str> = REQUIRED_READER_SECTIONS
        .iter()
        .filter(|section| !stripped.ends_with(*section))
        .copied()
        .collect();
    if !missing.is_empty() {
        let joined = missing.join(", ");
        return HookMessage::ReaderMissingSections { sections: joined }.into_result();
    }
    for block in CODE_BLOCK_RE.find_iter(&message) {
        if block.as_str().matches('\n').count() > CODE_BLOCK_LINE_LIMIT {
            return HookMessage::ReaderOversizedBlock.into_result();
        }
    }
    HookResult::allow()
}

fn validate_suite_runner(ctx: &HookContext) -> HookResult {
    if ctx.run.is_none() {
        return HookMessage::RunnerStateInvalid {
            details: "run context is missing; initialize the suite run first".into(),
        }
        .into_result();
    }
    let message = ctx.last_assistant_message();
    if message.is_empty() {
        return HookResult::allow();
    }
    let reply = match parse_preflight_reply(message) {
        Ok(r) => r,
        Err(detail) => {
            return HookMessage::PreflightReplyInvalid { details: detail }.into_result();
        }
    };
    let state = ctx.runner_state.as_ref();
    if reply.status == runner_rules::PREFLIGHT_REPLY_FAIL {
        if let Some(s) = state
            && s.phase == RunnerPhase::Preflight
        {
            let mut new_state = s.clone();
            new_state.preflight.status = PreflightStatus::Pending;
            new_state.transition_count += 1;
            new_state.last_event = Some("PreflightFailed".to_string());
            new_state.updated_at = chrono::Utc::now().to_rfc3339();
            if let Some(ref rd) = ctx.effective_run_dir() {
                let _ = runner_wf::write_runner_state(rd, &new_state);
            }
            return HookResult::allow();
        }
        return HookMessage::PreflightMissing.into_result();
    }
    // Pass reply - validate artifacts exist.
    if let Some(ref run) = ctx.run {
        if run.prepared_suite.is_none() || run.preflight.is_none() {
            return HookMessage::PreflightReplyInvalid {
                details: "preflight artifacts were not saved".into(),
            }
            .into_result();
        }
        if !run.layout.prepared_suite_path().exists() {
            return HookMessage::PreflightReplyInvalid {
                details: "prepared-suite artifact is missing or incomplete".into(),
            }
            .into_result();
        }
    }
    // Transition to preflight captured.
    if let Some(s) = state {
        if s.phase == RunnerPhase::Preflight {
            let mut new_state = s.clone();
            new_state.preflight.status = PreflightStatus::Complete;
            new_state.transition_count += 1;
            new_state.last_event = Some("PreflightCaptured".to_string());
            new_state.updated_at = chrono::Utc::now().to_rfc3339();
            if let Some(ref rd) = ctx.effective_run_dir() {
                let _ = runner_wf::write_runner_state(rd, &new_state);
            }
            return HookResult::allow();
        }
        if s.phase == RunnerPhase::Execution {
            return HookResult::allow();
        }
    }
    HookMessage::PreflightMissing.into_result()
}

struct PreflightReply {
    status: String,
}

fn parse_preflight_reply(message: &str) -> Result<PreflightReply, String> {
    let lines: Vec<&str> = message
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if lines.is_empty() {
        return Err("return the canonical preflight summary".to_string());
    }
    let head = runner_rules::PREFLIGHT_REPLY_HEAD;
    let pass = runner_rules::PREFLIGHT_REPLY_PASS;
    let fail = runner_rules::PREFLIGHT_REPLY_FAIL;
    let caps = PREFLIGHT_RE
        .captures(lines[0])
        .ok_or_else(|| format!("first line must be `{head} {pass}` or `{head} {fail}`"))?;
    let status = caps[1].to_string();
    let data: HashMap<String, String> = lines[1..]
        .iter()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            Some((key.trim().to_lowercase(), value.trim().to_string()))
        })
        .collect();
    if status == pass {
        if !data.contains_key("prepared suite") || !data.contains_key("state capture") {
            return Err(
                "pass replies must include `Prepared suite:` and `State capture:`".to_string(),
            );
        }
        if !data.contains_key("warnings") {
            return Err("pass replies must include a `Warnings:` line".to_string());
        }
    } else if !data.contains_key("blocker") {
        return Err("fail replies must include a `Blocker:` line".to_string());
    }
    Ok(PreflightReply { status })
}
