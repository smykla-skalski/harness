use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::TaskBoardTriageEscalationVerdictRequest;
use harness_kernel::errors::{CliError, CliErrorKind};
use crate::task_board::transport::{daemon_client, print_json};
use crate::task_board::{TriageVerdict, is_canonical_reason_detail};

/// The daemon-spawned escalation worker's only way to report its judgment
/// back. Never used interactively -- the escalation prompt
/// (`render_triage_escalation_prompt`) is the only place this exact command
/// line is ever produced.
#[derive(Debug, Clone, Args)]
pub struct TaskBoardTriageEscalationReportArgs {
    /// The escalation id from the prompt.
    pub escalation_id: String,
    /// The single-use token from the prompt -- the entire credential for
    /// this report, not the daemon's control-plane session token.
    #[arg(long)]
    pub token: String,
    /// The item's evidence fingerprint from the prompt.
    #[arg(long)]
    pub fingerprint: String,
    /// `todo` or `undecided`.
    #[arg(long)]
    pub verdict: String,
    /// At most 256 bytes, no control characters, and -- because the
    /// rendered prompt wraps this argument in single quotes -- no quote
    /// characters. Validated here so a non-conforming agent gets an
    /// immediate, actionable CLI error and can re-run with the same
    /// still-running token, instead of a confusing shell error or the
    /// daemon silently dropping an out-of-bounds rationale.
    #[arg(long)]
    pub rationale: String,
    #[arg(long)]
    pub json: bool,
}

impl Execute for TaskBoardTriageEscalationReportArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if !is_canonical_reason_detail(&self.rationale) {
            return Err(CliErrorKind::workflow_io(format!(
                "--rationale must be 1-256 bytes with no control characters (got {} bytes)",
                self.rationale.len()
            ))
            .into());
        }
        if let Some(quote) = self.rationale.chars().find(|c| matches!(c, '\'' | '"' | '`')) {
            return Err(CliErrorKind::workflow_io(format!(
                "--rationale must be plain text with no quote characters (found {quote:?})"
            ))
            .into());
        }
        let verdict = match self.verdict.as_str() {
            "todo" => TriageVerdict::Todo,
            "undecided" => TriageVerdict::Undecided,
            other => {
                return Err(CliErrorKind::workflow_io(format!(
                    "--verdict must be 'todo' or 'undecided', got '{other}'"
                ))
                .into());
            }
        };
        let request = TaskBoardTriageEscalationVerdictRequest {
            verdict_token: self.token.clone(),
            evidence_fingerprint: self.fingerprint.clone(),
            verdict,
            rationale: self.rationale.clone(),
        };
        let response = daemon_client()?
            .report_task_board_triage_escalation_verdict(&self.escalation_id, &request)?;
        if self.json {
            print_json(&response)?;
        } else if response.accepted {
            println!("triage escalation {}: verdict accepted", self.escalation_id);
        } else {
            println!(
                "triage escalation {}: rejected ({})",
                self.escalation_id,
                response.rejected_reason.as_deref().unwrap_or("unknown")
            );
        }
        Ok(i32::from(!response.accepted))
    }
}
