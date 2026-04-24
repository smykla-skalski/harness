use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::client::DaemonClient;
use crate::daemon::protocol::{
    TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::session::service;
use crate::session::types::{ReviewPoint, ReviewVerdict, TaskSeverity, TaskSource, TaskStatus};

use super::support::{print_json, resolve_project_dir};

#[derive(Debug, Clone, Args)]
pub struct TaskCreateArgs {
    /// Session ID.
    pub session_id: String,
    /// Task title.
    #[arg(long)]
    pub title: String,
    /// Task context.
    #[arg(long)]
    pub context: Option<String>,
    /// Severity level.
    #[arg(long, value_enum, default_value = "medium")]
    pub severity: TaskSeverity,
    /// Suggested fix, if already known.
    #[arg(long)]
    pub suggested_fix: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let spec = service::TaskSpec {
            title: &self.title,
            context: self.context.as_deref(),
            severity: self.severity,
            suggested_fix: self.suggested_fix.as_deref(),
            source: TaskSource::Manual,
            observe_issue_id: None,
        };
        let item =
            service::create_task_with_source(&self.session_id, &spec, &self.actor, &project)?;
        print_json(&item)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskAssignArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID to assign.
    pub task_id: String,
    /// Agent ID to assign to.
    pub agent_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskAssignArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::assign_task(
            &self.session_id,
            &self.task_id,
            &self.agent_id,
            &self.actor,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskListArgs {
    /// Session ID.
    pub session_id: String,
    /// Filter by status.
    #[arg(long, value_enum)]
    pub status: Option<TaskStatus>,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let items = service::list_tasks(&self.session_id, self.status, &project)?;
        if self.json {
            print_json(&items)?;
        } else {
            for item in &items {
                println!(
                    "[{:?}] {} - {} (assigned: {}, progress: {})",
                    item.severity,
                    item.task_id,
                    item.title,
                    item.assigned_to.as_deref().unwrap_or("unassigned"),
                    item.checkpoint_summary.as_ref().map_or_else(
                        || "-".to_string(),
                        |summary| format!("{}%", summary.progress)
                    ),
                );
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskUpdateArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID to update.
    pub task_id: String,
    /// New status.
    #[arg(long, value_enum)]
    pub status: TaskStatus,
    /// Optional note.
    #[arg(long)]
    pub note: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskUpdateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::update_task(
            &self.session_id,
            &self.task_id,
            self.status,
            self.note.as_deref(),
            &self.actor,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskCheckpointArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID.
    pub task_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Human-readable checkpoint summary.
    #[arg(long)]
    pub summary: String,
    /// Progress percentage.
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=100))]
    pub progress: u8,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskCheckpointArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let checkpoint = service::record_task_checkpoint(
            &self.session_id,
            &self.task_id,
            &self.actor,
            &self.summary,
            self.progress,
            &project,
        )?;
        print_json(&checkpoint)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskSubmitForReviewArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID to return for review.
    pub task_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Optional short summary of the worker's hand-off.
    #[arg(long)]
    pub summary: Option<String>,
    /// Optional persona hint for the reviewer queue.
    #[arg(long)]
    pub suggested_persona: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskSubmitForReviewArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if let Some(client) = DaemonClient::try_connect() {
            client.submit_task_for_review(
                &self.session_id,
                &self.task_id,
                &TaskSubmitForReviewRequest {
                    actor: self.actor.clone(),
                    summary: self.summary.clone(),
                    suggested_persona: self.suggested_persona.clone(),
                },
            )?;
            return Ok(0);
        }
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::submit_for_review_with_persona(
            &self.session_id,
            &self.task_id,
            &self.actor,
            self.summary.as_deref(),
            self.suggested_persona.as_deref(),
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskClaimReviewArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID to claim for review.
    pub task_id: String,
    /// Agent ID of the reviewer claiming the task.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskClaimReviewArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if let Some(client) = DaemonClient::try_connect() {
            client.claim_task_review(
                &self.session_id,
                &self.task_id,
                &TaskClaimReviewRequest {
                    actor: self.actor.clone(),
                },
            )?;
            return Ok(0);
        }
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::claim_review(&self.session_id, &self.task_id, &self.actor, &project)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskSubmitReviewArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID under review.
    pub task_id: String,
    /// Agent ID of the reviewer.
    #[arg(long)]
    pub actor: String,
    /// Overall verdict.
    #[arg(long, value_enum)]
    pub verdict: ReviewVerdict,
    /// Human-readable summary of the review.
    #[arg(long)]
    pub summary: String,
    /// JSON array of review points (`ReviewPoint`). Defaults to empty.
    #[arg(long)]
    pub points: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskSubmitReviewArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let points = parse_review_points(self.points.as_deref())?;
        if let Some(client) = DaemonClient::try_connect() {
            client.submit_task_review(
                &self.session_id,
                &self.task_id,
                &TaskSubmitReviewRequest {
                    actor: self.actor.clone(),
                    verdict: self.verdict,
                    summary: self.summary.clone(),
                    points,
                },
            )?;
            return Ok(0);
        }
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let _review = service::submit_review(
            &self.session_id,
            &self.task_id,
            &self.actor,
            self.verdict,
            &self.summary,
            points,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskRespondReviewArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID the worker is responding on.
    pub task_id: String,
    /// Agent ID of the worker.
    #[arg(long)]
    pub actor: String,
    /// Comma-separated point ids the worker agrees with.
    #[arg(long, value_delimiter = ',')]
    pub agreed: Vec<String>,
    /// Comma-separated point ids the worker disputes.
    #[arg(long, value_delimiter = ',')]
    pub disputed: Vec<String>,
    /// Optional worker note.
    #[arg(long)]
    pub note: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskRespondReviewArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if let Some(client) = DaemonClient::try_connect() {
            client.respond_task_review(
                &self.session_id,
                &self.task_id,
                &TaskRespondReviewRequest {
                    actor: self.actor.clone(),
                    agreed: self.agreed.clone(),
                    disputed: self.disputed.clone(),
                    note: self.note.clone(),
                },
            )?;
            return Ok(0);
        }
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::respond_review(
            &self.session_id,
            &self.task_id,
            &self.actor,
            &self.agreed,
            &self.disputed,
            self.note.as_deref(),
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskArbitrateArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID awaiting arbitration.
    pub task_id: String,
    /// Agent ID of the leader arbitrating.
    #[arg(long)]
    pub actor: String,
    /// Final arbitration verdict.
    #[arg(long, value_enum)]
    pub verdict: ReviewVerdict,
    /// Human-readable arbitration summary.
    #[arg(long)]
    pub summary: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskArbitrateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        if let Some(client) = DaemonClient::try_connect() {
            client.arbitrate_task(
                &self.session_id,
                &self.task_id,
                &TaskArbitrateRequest {
                    actor: self.actor.clone(),
                    verdict: self.verdict,
                    summary: self.summary.clone(),
                },
            )?;
            return Ok(0);
        }
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::arbitrate(
            &self.session_id,
            &self.task_id,
            &self.actor,
            self.verdict,
            &self.summary,
            &project,
        )?;
        Ok(0)
    }
}

fn parse_review_points(raw: Option<&str>) -> Result<Vec<ReviewPoint>, CliError> {
    let Some(value) = raw else {
        return Ok(Vec::new());
    };
    serde_json::from_str::<Vec<ReviewPoint>>(value).map_err(|error| {
        CliErrorKind::usage_error(format!("invalid --points JSON: {error}")).into()
    })
}
