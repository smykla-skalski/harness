use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner::{self as runner_rules, PreflightReply};
use crate::workflow::runner::RunnerPhase;

use super::effects;

static CODE_BLOCK_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)```.*?```").unwrap());

static PREFLIGHT_RE: LazyLock<Regex> = LazyLock::new(|| {
    let head = runner_rules::PREFLIGHT_REPLY_HEAD;
    let pattern = format!(
        r"^{}\s*({}|{})$",
        regex::escape(head),
        PreflightReply::Pass,
        PreflightReply::Fail,
    );
    Regex::new(&pattern).unwrap()
});

const CODE_BLOCK_LINE_LIMIT: usize = 60;

/// Execute the validate-agent hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    super::dispatch_by_skill(ctx, validate_suite_runner, |ctx| {
        Ok(validate_suite_author(ctx))
    })
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
    if !stripped.ends_with("saved") {
        return HookMessage::reader_missing_sections("saved").into_result();
    }
    for block in CODE_BLOCK_RE.find_iter(&message) {
        if block.as_str().matches('\n').count() > CODE_BLOCK_LINE_LIMIT {
            return HookMessage::ReaderOversizedBlock.into_result();
        }
    }
    HookResult::allow()
}

fn validate_suite_runner(ctx: &HookContext) -> Result<HookResult, CliError> {
    if ctx.run.is_none() {
        return Ok(HookMessage::runner_state_invalid(
            "run context is missing; initialize the suite run first",
        )
        .into_result());
    }
    let message = ctx.last_assistant_message();
    if message.is_empty() {
        return Ok(HookResult::allow());
    }
    let reply = match parse_preflight_reply(message) {
        Ok(r) => r,
        Err(detail) => {
            return Ok(HookMessage::preflight_reply_invalid(detail).into_result());
        }
    };
    let state = ctx.runner_state.as_ref();
    if reply.status == PreflightReply::Fail {
        if let Some(s) = state
            && s.phase() == RunnerPhase::Preflight
        {
            let _ = effects::transition_runner_state(ctx, |state| {
                (state.phase() == RunnerPhase::Preflight)
                    .then(|| state.request_preflight_failed("PreflightFailed"))
            })?;
            return Ok(HookResult::allow());
        }
        return Ok(HookMessage::PreflightMissing.into_result());
    }
    // Pass reply - validate artifacts exist.
    if let Some(ref run) = ctx.run {
        if run.prepared_suite.is_none() || run.preflight.is_none() {
            return Ok(
                HookMessage::preflight_reply_invalid("preflight artifacts were not saved")
                    .into_result(),
            );
        }
        if !run.layout.prepared_suite_path().exists() {
            return Ok(HookMessage::preflight_reply_invalid(
                "prepared-suite artifact is missing or incomplete",
            )
            .into_result());
        }
    }
    // Transition to preflight captured.
    if let Some(s) = state {
        if s.phase() == RunnerPhase::Preflight {
            let _ = effects::transition_runner_state(ctx, |state| {
                (state.phase() == RunnerPhase::Preflight)
                    .then(|| state.record_preflight_captured("PreflightCaptured"))
            })?;
            return Ok(HookResult::allow());
        }
        if s.phase() == RunnerPhase::Execution {
            return Ok(HookResult::allow());
        }
    }
    Ok(HookMessage::PreflightMissing.into_result())
}

#[derive(Debug)]
struct ParsedPreflight {
    status: PreflightReply,
}

fn parse_preflight_reply(message: &str) -> Result<ParsedPreflight, String> {
    let lines: Vec<&str> = message
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    if lines.is_empty() {
        return Err("return the canonical preflight summary".to_string());
    }
    let head = runner_rules::PREFLIGHT_REPLY_HEAD;
    let pass = PreflightReply::Pass;
    let fail = PreflightReply::Fail;
    let caps = PREFLIGHT_RE
        .captures(lines[0])
        .ok_or_else(|| format!("first line must be `{head} {pass}` or `{head} {fail}`"))?;
    let raw = caps
        .get(1)
        .map(|m| m.as_str())
        .ok_or_else(|| format!("first line must be `{head} {pass}` or `{head} {fail}`"))?;
    let status: PreflightReply = raw
        .parse()
        .map_err(|()| format!("first line must be `{head} {pass}` or `{head} {fail}`"))?;
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
    Ok(ParsedPreflight { status })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn head() -> &'static str {
        runner_rules::PREFLIGHT_REPLY_HEAD
    }

    #[test]
    fn parse_preflight_reply_pass() {
        let msg = format!(
            "{} pass\nPrepared suite: path/to/suite\nState capture: path/to/state\nWarnings: none",
            head()
        );
        let parsed = parse_preflight_reply(&msg).unwrap();
        assert_eq!(parsed.status, PreflightReply::Pass);
    }

    #[test]
    fn parse_preflight_reply_fail() {
        let msg = format!("{} fail\nBlocker: cluster unreachable", head());
        let parsed = parse_preflight_reply(&msg).unwrap();
        assert_eq!(parsed.status, PreflightReply::Fail);
    }

    #[test]
    fn parse_preflight_reply_rejects_empty() {
        let err = parse_preflight_reply("").unwrap_err();
        assert!(err.contains("preflight summary"), "got: {err}");
    }

    #[test]
    fn parse_preflight_reply_rejects_garbage() {
        let err = parse_preflight_reply("hello world").unwrap_err();
        assert!(err.contains("first line must be"), "got: {err}");
    }

    #[test]
    fn parse_preflight_reply_pass_requires_fields() {
        let msg = format!("{} pass", head());
        let err = parse_preflight_reply(&msg).unwrap_err();
        assert!(err.contains("Prepared suite"), "got: {err}");
    }
}
