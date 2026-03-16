use crate::audit_log::{append_audit_entry, build_hook_audit_request};
use crate::errors::CliError;
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

/// Execute the audit hook.
///
/// Logs suite:new hook debug info without affecting the main hook decision.
/// For suite:run or inactive contexts, allow unconditionally.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    super::dispatch_by_skill(
        ctx,
        |ctx| {
            if ctx.effective_run_dir().is_none() {
                return Ok(HookResult::allow());
            }
            match build_hook_audit_request(ctx).and_then(append_audit_entry) {
                Ok(_) => Ok(HookResult::allow()),
                Err(error) => Ok(HookResult::warn(
                    "KSR006",
                    format!("audit log write failed: {error}"),
                )),
            }
        },
        |_ctx| Ok(HookResult::allow()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use harness_testkit::RunDirBuilder;

    use crate::context::RunContext;
    use crate::hook::Decision;
    use crate::hook_payloads::{HookContext, HookEnvelopePayload};
    use crate::workflow::runner::{
        PreflightState, PreflightStatus, RunnerPhase, RunnerWorkflowState,
    };

    fn ctx_audit(skill: &str) -> HookContext {
        HookContext::from_envelope(
            skill,
            HookEnvelopePayload {
                tool_name: String::new(),
                tool_input: serde_json::Value::Null,
                tool_response: serde_json::Value::Null,
                last_assistant_message: None,
                transcript_path: None,
                stop_hook_active: false,
                raw_keys: vec![],
            },
        )
    }

    // -- Python: test_audit_is_silent_suite_runner --
    #[test]
    fn is_silent_suite_runner() {
        let c = ctx_audit("suite:run");
        let result = execute(&c).unwrap();
        assert_eq!(result.decision, Decision::Allow);
        assert!(result.code.is_empty());
    }

    // -- Python: test_audit_is_silent_suite_author --
    #[test]
    fn is_silent_suite_author() {
        let c = ctx_audit("suite:new");
        let result = execute(&c).unwrap();
        assert_eq!(result.decision, Decision::Allow);
        assert!(result.code.is_empty());
    }

    #[test]
    fn allows_inactive_skill() {
        let mut c = ctx_audit("suite:run");
        c.skill_active = false;
        let result = execute(&c).unwrap();
        assert_eq!(result.decision, Decision::Allow);
    }

    #[test]
    fn writes_audit_entry_for_suite_run_hook() {
        let tempdir = tempfile::tempdir().unwrap();
        let run_dir = RunDirBuilder::new(tempdir.path(), "r01").build_run_dir();
        let mut run_context = RunContext::from_run_dir(&run_dir).unwrap();
        let mut status = run_context.status.take().unwrap();
        status.next_planned_group = Some("g01".to_string());
        run_context.status = Some(status);

        let context = HookContext {
            skill: "suite:run".to_string(),
            event: crate::hook_payloads::HookEvent {
                payload: HookEnvelopePayload {
                    tool_name: "Bash".to_string(),
                    tool_input: serde_json::json!({
                        "command": "harness record --phase verify --gid g01 -- echo hello",
                    }),
                    tool_response: serde_json::json!({
                        "stdout": "hello\n",
                        "stderr": "",
                        "exit_code": 0,
                    }),
                    last_assistant_message: None,
                    transcript_path: None,
                    stop_hook_active: false,
                    raw_keys: vec![],
                },
            },
            run_dir: Some(run_dir.clone()),
            skill_active: true,
            active_skill: Some("suite:run".to_string()),
            inactive_reason: None,
            run: Some(run_context),
            runner_state: Some(RunnerWorkflowState {
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
            }),
            author_state: None,
        };

        let result = execute(&context).unwrap();
        assert_eq!(result.decision, Decision::Allow);

        let log_path = run_dir.join("audit-log.jsonl");
        let contents = fs::read_to_string(&log_path).unwrap();
        assert!(contents.contains("\"tool_name\":\"Bash\""));
        assert!(contents.contains("\"group_id\":\"g01\""));
        assert!(contents.contains("\"phase\":\"execution\""));
    }

    #[test]
    fn allows_when_run_context_is_missing() {
        let context = HookContext::from_envelope(
            "suite:run",
            HookEnvelopePayload {
                tool_name: "Read".to_string(),
                tool_input: serde_json::json!({
                    "file_path": "/tmp/test.txt",
                }),
                tool_response: serde_json::Value::Null,
                last_assistant_message: None,
                transcript_path: None,
                stop_hook_active: false,
                raw_keys: vec![],
            },
        );

        let result = execute(&context).unwrap();
        assert_eq!(result.decision, Decision::Allow);
    }
}
