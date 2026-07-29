use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};

use super::{TaskBoardDependencyRouteRecord, TaskBoardDependencyRouteStatus};
use crate::github::{
    CheckState, CheckWait, CheckWaitControls, CheckWaitOutcome, PullRequestEvidence,
    PullRequestEvidenceSource, PullRequestIdentity, poll_check_wait,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencySettledCheck {
    pub name: String,
    pub conclusion: CheckState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TaskBoardDependencyCheckResumeStatus {
    ChecksPassed {
        checks: Vec<TaskBoardDependencySettledCheck>,
    },
    ChecksFailed {
        checks: Vec<TaskBoardDependencySettledCheck>,
    },
    HeadChanged {
        observed_head: String,
    },
    PullRequestVanished,
    TimedOut,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyCheckWait {
    pub resume_id: String,
    pub route_id: String,
    pub identity: PullRequestIdentity,
    pub exact_head_revision: String,
    pub required_checks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyCheckResumeRecord {
    pub resume_id: String,
    pub route_id: String,
    pub identity: PullRequestIdentity,
    pub exact_head_revision: String,
    pub status: TaskBoardDependencyCheckResumeStatus,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardDependencyCheckResumeAdmission {
    Resumed,
    Duplicate(Box<TaskBoardDependencyCheckResumeRecord>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyCheckResumeOutcome {
    pub record: TaskBoardDependencyCheckResumeRecord,
    pub created: bool,
}

#[async_trait]
pub trait TaskBoardDependencyCheckResumeSink: Send + Sync {
    /// Atomically persist one terminal wait outcome and resume the workflow.
    ///
    /// `Resumed` must be returned only by the caller that performed the transition. A duplicate
    /// returns the previously stored record and must perform no second workflow transition.
    ///
    /// # Errors
    ///
    /// Returns a storage or workflow-transition error without claiming the resume id.
    async fn resume_once(
        &self,
        record: TaskBoardDependencyCheckResumeRecord,
    ) -> Result<TaskBoardDependencyCheckResumeAdmission, CliError>;
}

/// Convert one admitted waiting route into an exact-head check wait.
///
/// # Errors
///
/// Rejects non-wait routes and waiting routes without a complete target or required checks.
pub fn task_board_dependency_check_wait(
    route: &TaskBoardDependencyRouteRecord,
    evidence: &PullRequestEvidence,
) -> Result<TaskBoardDependencyCheckWait, CliError> {
    let TaskBoardDependencyRouteStatus::WaitingForChecks { pending_checks } = &route.status else {
        return Err(CliErrorKind::workflow_parse(
            "dependency triage route is not waiting for checks",
        )
        .into());
    };
    let required_checks = &evidence.gates.required_check_names;
    let identity_matches = evidence.identity.repository == route.repository
        && evidence.identity.number == route.pull_request_number
        && evidence.head_revision == route.exact_head_revision
        && route.source_result.repository == route.repository
        && route.source_result.pull_request_number == route.pull_request_number
        && route.source_result.exact_head_revision == route.exact_head_revision;
    let pending_checks_are_required = pending_checks.iter().all(|name| {
        required_checks.contains(name)
            && evidence.gates.check_state(name) == Some(CheckState::Pending)
    });
    if route.route_id.trim().is_empty()
        || route.repository.trim().is_empty()
        || route.pull_request_number == 0
        || route.exact_head_revision.trim().is_empty()
        || !identity_matches
        || pending_checks.is_empty()
        || pending_checks.iter().any(|name| name.trim().is_empty())
        || required_checks.is_empty()
        || !pending_checks_are_required
    {
        return Err(CliErrorKind::workflow_parse(
            "dependency check wait has incomplete exact-head evidence",
        )
        .into());
    }
    Ok(TaskBoardDependencyCheckWait {
        resume_id: format!("{}:checks", route.route_id),
        route_id: route.route_id.clone(),
        identity: PullRequestIdentity::from_slug(
            route.repository.clone(),
            route.pull_request_number,
        ),
        exact_head_revision: route.exact_head_revision.clone(),
        required_checks: required_checks.clone(),
    })
}

/// Observe a dependency check wait to a distinct terminal outcome and resume it at most once.
///
/// # Errors
///
/// Returns provider errors, malformed completion evidence, resume-id collisions, or sink errors.
pub async fn observe_task_board_dependency_check_wait(
    source: &dyn PullRequestEvidenceSource,
    wait: &TaskBoardDependencyCheckWait,
    controls: CheckWaitControls<'_>,
    sink: &dyn TaskBoardDependencyCheckResumeSink,
) -> Result<TaskBoardDependencyCheckResumeOutcome, CliError> {
    let check_wait = CheckWait {
        identity: wait.identity.clone(),
        head_revision: wait.exact_head_revision.clone(),
        required_checks: wait.required_checks.clone(),
    };
    let outcome = poll_check_wait(source, &check_wait, controls).await?;
    let record = TaskBoardDependencyCheckResumeRecord {
        resume_id: wait.resume_id.clone(),
        route_id: wait.route_id.clone(),
        identity: wait.identity.clone(),
        exact_head_revision: wait.exact_head_revision.clone(),
        status: resume_status(outcome, &wait.required_checks)?,
    };
    match sink.resume_once(record.clone()).await? {
        TaskBoardDependencyCheckResumeAdmission::Resumed => {
            Ok(TaskBoardDependencyCheckResumeOutcome {
                record,
                created: true,
            })
        }
        TaskBoardDependencyCheckResumeAdmission::Duplicate(existing) if *existing == record => {
            Ok(TaskBoardDependencyCheckResumeOutcome {
                record: *existing,
                created: false,
            })
        }
        TaskBoardDependencyCheckResumeAdmission::Duplicate(_) => {
            Err(CliErrorKind::workflow_io(format!(
                "dependency check resume id reused for different content: {}",
                record.resume_id
            ))
            .into())
        }
    }
}

fn resume_status(
    outcome: CheckWaitOutcome,
    required_checks: &[String],
) -> Result<TaskBoardDependencyCheckResumeStatus, CliError> {
    match outcome {
        CheckWaitOutcome::Completed(evidence) => settled_status(&evidence, required_checks),
        CheckWaitOutcome::Superseded { observed_head } => {
            Ok(TaskBoardDependencyCheckResumeStatus::HeadChanged { observed_head })
        }
        CheckWaitOutcome::Vanished => Ok(TaskBoardDependencyCheckResumeStatus::PullRequestVanished),
        CheckWaitOutcome::TimedOut => Ok(TaskBoardDependencyCheckResumeStatus::TimedOut),
        CheckWaitOutcome::Cancelled => Ok(TaskBoardDependencyCheckResumeStatus::Cancelled),
    }
}

fn settled_status(
    evidence: &PullRequestEvidence,
    required_checks: &[String],
) -> Result<TaskBoardDependencyCheckResumeStatus, CliError> {
    let mut checks = Vec::with_capacity(required_checks.len());
    for name in required_checks {
        let gate = evidence
            .gates
            .checks
            .iter()
            .find(|gate| gate.name == *name)
            .ok_or_else(|| {
                CliErrorKind::workflow_parse(format!(
                    "settled dependency check evidence is missing required check: {name}"
                ))
            })?;
        checks.push(TaskBoardDependencySettledCheck {
            name: gate.name.clone(),
            conclusion: gate.state,
            details_url: gate.details_url.clone(),
        });
    }
    let failed = checks
        .iter()
        .filter(|check| check.conclusion == CheckState::Failure)
        .cloned()
        .collect::<Vec<_>>();
    if failed.is_empty() {
        Ok(TaskBoardDependencyCheckResumeStatus::ChecksPassed { checks })
    } else {
        Ok(TaskBoardDependencyCheckResumeStatus::ChecksFailed { checks: failed })
    }
}

#[cfg(test)]
mod tests;
