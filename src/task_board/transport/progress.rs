use clap::{Args, Subcommand};

use crate::task_board::transport::{leaf_daemon_client, leaf_daemon_client_error, print_json};
use crate::task_board::wire::{
    TaskBoardWorkItemProgressResponse, TaskBoardWorkItemReportRequest,
    TaskBoardWorkItemReportResponse,
};
use crate::task_board::{TaskBoardWorkItemProgress, TaskBoardWorkItemState};
use harness_kernel::errors::CliError;
use harness_workspace::command_context::{AppContext, Execute};

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardProgressCommand {
    /// Record a checkpoint against the dispatched work item.
    Checkpoint(TaskBoardProgressCheckpointArgs),
    /// Hand the work item to review, keeping the attempt that produced it.
    #[command(name = "submit-for-review")]
    SubmitForReview(TaskBoardProgressSubmitArgs),
    /// Report the work item as finished.
    Complete(TaskBoardProgressCompleteArgs),
    /// Report the work item as stalled and needing a human.
    Block(TaskBoardProgressBlockArgs),
    /// Show the current progress and checkpoint log.
    Show(TaskBoardProgressShowArgs),
}

impl Execute for TaskBoardProgressCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Checkpoint(args) => args.execute(context),
            Self::SubmitForReview(args) => args.execute(context),
            Self::Complete(args) => args.execute(context),
            Self::Block(args) => args.execute(context),
            Self::Show(args) => args.execute(context),
        }
    }
}

/// The arguments every reporting subcommand shares. `sequence` is what makes a
/// retried delivery detectable: without it the daemon takes the next sequence
/// and cannot tell a retry from a fresh report.
#[derive(Debug, Clone, Args)]
pub struct TaskBoardProgressCommonArgs {
    /// Task-board item identifier.
    #[arg(long = "item-id", visible_alias = "id")]
    pub item_id: String,
    /// The agent reporting. Defaults to the calling principal.
    #[arg(long)]
    pub actor: Option<String>,
    /// Ordering fence; must be greater than the last accepted report.
    #[arg(long)]
    pub sequence: Option<u64>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardProgressCheckpointArgs {
    #[command(flatten)]
    pub common: TaskBoardProgressCommonArgs,
    /// What the worker has done since the last checkpoint.
    #[arg(long)]
    pub summary: String,
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=100))]
    pub progress: Option<u8>,
}

impl Execute for TaskBoardProgressCheckpointArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        report(
            &self.common,
            &TaskBoardWorkItemReportRequest {
                actor: self.common.actor.clone(),
                // No state: the daemon reads a bare checkpoint as "still
                // going" and promotes a pending or sent-back work item to
                // running on its own.
                state: None,
                summary: Some(self.summary.clone()),
                progress_percent: self.progress,
                blocked_reason: None,
                sequence: self.common.sequence,
            },
        )
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardProgressSubmitArgs {
    #[command(flatten)]
    pub common: TaskBoardProgressCommonArgs,
    /// What the reviewer should look at.
    #[arg(long)]
    pub summary: Option<String>,
}

impl Execute for TaskBoardProgressSubmitArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        report(
            &self.common,
            &TaskBoardWorkItemReportRequest {
                actor: self.common.actor.clone(),
                state: Some(TaskBoardWorkItemState::AwaitingReview),
                summary: self.summary.clone(),
                progress_percent: None,
                blocked_reason: None,
                sequence: self.common.sequence,
            },
        )
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardProgressCompleteArgs {
    #[command(flatten)]
    pub common: TaskBoardProgressCommonArgs,
    #[arg(long)]
    pub summary: Option<String>,
}

impl Execute for TaskBoardProgressCompleteArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        report(
            &self.common,
            &TaskBoardWorkItemReportRequest {
                actor: self.common.actor.clone(),
                state: Some(TaskBoardWorkItemState::Done),
                summary: self.summary.clone(),
                progress_percent: None,
                blocked_reason: None,
                sequence: self.common.sequence,
            },
        )
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardProgressBlockArgs {
    #[command(flatten)]
    pub common: TaskBoardProgressCommonArgs,
    /// Why the work cannot continue.
    #[arg(long)]
    pub reason: String,
}

impl Execute for TaskBoardProgressBlockArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        report(
            &self.common,
            &TaskBoardWorkItemReportRequest {
                actor: self.common.actor.clone(),
                state: Some(TaskBoardWorkItemState::Blocked),
                summary: None,
                progress_percent: None,
                blocked_reason: Some(self.reason.clone()),
                sequence: self.common.sequence,
            },
        )
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardProgressShowArgs {
    #[arg(long = "item-id", visible_alias = "id")]
    pub item_id: String,
    #[arg(long)]
    pub json: bool,
}

impl Execute for TaskBoardProgressShowArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response: TaskBoardWorkItemProgressResponse = leaf_daemon_client()?
            .get(&progress_url(&self.item_id), &[])
            .map_err(|error| leaf_daemon_client_error("read task-board progress", &error))?;
        if self.json {
            print_json(&response)?;
            return Ok(0);
        }
        let Some(progress) = response.progress.as_ref() else {
            println!("task-board progress: item has not been dispatched");
            return Ok(0);
        };
        print_progress(progress);
        for checkpoint in &progress.checkpoints {
            println!(
                "  {} [{}] {}",
                checkpoint.sequence, checkpoint.actor, checkpoint.summary
            );
        }
        Ok(0)
    }
}

fn report(
    common: &TaskBoardProgressCommonArgs,
    request: &TaskBoardWorkItemReportRequest,
) -> Result<i32, CliError> {
    let response: TaskBoardWorkItemReportResponse = leaf_daemon_client()?
        .post(&report_url(&common.item_id), &request)
        .map_err(|error| leaf_daemon_client_error("report task-board progress", &error))?;
    if common.json {
        print_json(&response)?;
        return Ok(0);
    }
    if let Some(message) = response.rejection_message.as_deref() {
        println!("task-board progress: {message}");
    }
    print_progress(&response.progress);
    Ok(0)
}

fn print_progress(progress: &TaskBoardWorkItemProgress) {
    let percent = progress
        .progress_percent
        .map_or_else(String::new, |percent| format!(" {percent}%"));
    println!(
        "task-board progress: {}{percent} (report {})",
        progress.state.as_str(),
        progress.report_sequence
    );
    if let Some(reason) = progress.blocked_reason.as_deref() {
        println!("  blocked: {reason}");
    }
}

fn report_url(item_id: &str) -> String {
    format!("/v1/task-board/items/{item_id}/progress/report")
}

fn progress_url(item_id: &str) -> String {
    format!("/v1/task-board/items/{item_id}/progress")
}
