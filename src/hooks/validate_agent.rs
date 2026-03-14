use regex::Regex;

use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;

/// Required sections in a suite-author worker reply acknowledgement.
const REQUIRED_READER_SECTIONS: &[&str] = &["saved"];

/// Max lines in a code block before it is considered oversized.
const CODE_BLOCK_LINE_LIMIT: usize = 60;

/// Execute the validate-agent hook.
///
/// For suite-author: validates worker reply format (must end with
/// required section keywords, code blocks must not be oversized).
/// For suite-runner: validates preflight worker reply format and
/// artifacts. Full artifact validation needs `RunContext` and runner
/// workflow state.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.skill == "suite-author" {
        return validate_suite_author(ctx);
    }
    validate_suite_runner(ctx)
}

fn validate_suite_author(ctx: &HookContext) -> Result<HookResult, CliError> {
    if ctx.stop_hook_active() {
        return Ok(HookResult::allow());
    }
    let message = ctx.last_assistant_message().to_lowercase();
    if message.is_empty() {
        return Ok(HookResult::allow());
    }
    let stripped = message.trim_end_matches('.');
    let missing: Vec<&str> = REQUIRED_READER_SECTIONS
        .iter()
        .filter(|section| !stripped.ends_with(*section))
        .copied()
        .collect();
    if !missing.is_empty() {
        let joined = missing.join(", ");
        return Ok(errors::hook_msg(
            &errors::WARN_READER_MISSING_SECTIONS,
            &[("sections", &joined)],
        ));
    }
    // Check for oversized code blocks.
    let block_re = Regex::new(r"(?s)```.*?```").expect("code block regex should compile");
    for block in block_re.find_iter(&message) {
        if block.as_str().matches('\n').count() > CODE_BLOCK_LINE_LIMIT {
            return Ok(errors::hook_msg(&errors::WARN_READER_OVERSIZED_BLOCK, &[]));
        }
    }
    Ok(HookResult::allow())
}

fn validate_suite_runner(ctx: &HookContext) -> Result<HookResult, CliError> {
    if ctx.run_dir.is_none() {
        return Ok(errors::hook_msg(
            &errors::DENY_RUNNER_STATE_INVALID,
            &[(
                "details",
                "run context is missing; initialize the suite run first",
            )],
        ));
    }
    let message = ctx.last_assistant_message();
    if message.is_empty() {
        return Ok(HookResult::allow());
    }
    // Validate the preflight reply format.
    match parse_preflight_reply(&message) {
        Ok(reply) => {
            if reply.status == runner_rules::PREFLIGHT_REPLY_FAIL {
                // Full implementation updates runner state to
                // request_preflight_failed. Without state, allow.
                return Ok(HookResult::allow());
            }
            // Pass reply - full implementation validates artifacts and
            // updates runner state. Without RunContext, allow.
            Ok(HookResult::allow())
        }
        Err(detail) => Ok(errors::hook_msg(
            &errors::DENY_PREFLIGHT_REPLY_INVALID,
            &[("details", &detail)],
        )),
    }
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
    let pattern = format!(r"^{}\s*({pass}|{fail})$", regex::escape(head));
    let re = Regex::new(&pattern).expect("preflight regex should compile");
    let caps = re
        .captures(lines[0])
        .ok_or_else(|| format!("first line must be `{head} {pass}` or `{head} {fail}`"))?;
    let status = caps[1].to_string();
    Ok(PreflightReply { status })
}
