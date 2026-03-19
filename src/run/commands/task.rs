use clap::{Args, Subcommand};

use crate::app::command_context::{CommandContext, Execute};
use crate::errors::CliError;
use crate::run::services::{tail_task_output, wait_for_task_output};

impl Execute for TaskArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        task(&self.command)
    }
}

/// Background task output operations.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskCommand {
    /// Wait for a background task to complete by polling its output file.
    Wait {
        /// Full path to the task output file.
        output_file: String,
        /// Maximum seconds to wait before timing out.
        #[arg(long, default_value = "600")]
        timeout: u64,
        /// Seconds between file-size polls.
        #[arg(long, default_value = "10")]
        poll_interval: u64,
        /// Number of tail lines to print when done.
        #[arg(long, default_value = "20")]
        lines: usize,
    },
    /// Print the last N lines of a task output file.
    Tail {
        /// Full path to the task output file.
        output_file: String,
        /// Number of lines to print.
        #[arg(long, default_value = "20")]
        lines: usize,
    },
}

/// Arguments for `harness task`.
#[derive(Debug, Clone, Args)]
pub struct TaskArgs {
    /// Task subcommand.
    #[command(subcommand)]
    pub command: TaskCommand,
}

/// Dispatch a task subcommand.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn task(command: &TaskCommand) -> Result<i32, CliError> {
    let lines = match command {
        TaskCommand::Wait {
            output_file,
            timeout,
            poll_interval,
            lines,
        } => wait_for_task_output(output_file, *timeout, *poll_interval, *lines)?,
        TaskCommand::Tail { output_file, lines } => tail_task_output(output_file, *lines)?,
    };

    for line in lines {
        println!("{line}");
    }

    Ok(0)
}
