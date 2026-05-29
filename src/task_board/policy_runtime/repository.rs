use std::path::PathBuf;

use chrono::{DateTime, Utc};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::persistence::versioned_json::VersionedJsonRepository;

use super::events::run_matches_event;
use super::models::{
    POLICY_WORKFLOW_RUNS_SCHEMA_VERSION, PolicyRunStatus, PolicyRunTrigger, PolicyWorkflowEvent,
    PolicyWorkflowRun, PolicyWorkflowRunsDocument,
};
use super::scheduler::timer_wait_is_due;

/// A `Running` run whose `updated_at` is older than this is treated as
/// abandoned (its executor crashed or was killed), so a new run may take
/// over instead of being blocked forever by a stuck record.
const STALE_RUNNING_SECONDS: i64 = 600;

/// Outcome of an atomic [`PolicyRuntimeRepository::begin_run`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BeginRunOutcome {
    /// A fresh run was inserted and should be executed by the caller.
    Created(PolicyWorkflowRun),
    /// A live run already existed for this workflow + subject; reuse it.
    Existing(PolicyWorkflowRun),
}

pub struct PolicyRuntimeRepository {
    repository: VersionedJsonRepository<PolicyWorkflowRunsDocument>,
}

impl PolicyRuntimeRepository {
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self {
            repository: VersionedJsonRepository::new(
                root.join("policy-workflow-runs-v1.json"),
                POLICY_WORKFLOW_RUNS_SCHEMA_VERSION,
            ),
        }
    }

    pub fn save(&self, run: &PolicyWorkflowRun) -> Result<(), CliError> {
        let run = run.clone();
        let _ = self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            if let Some(existing) = document
                .runs
                .iter_mut()
                .find(|existing| existing.run_id == run.run_id)
            {
                *existing = run.clone();
            } else {
                document.runs.push(run.clone());
            }
            Ok(Some(document))
        })?;
        Ok(())
    }

    /// Atomically dedupe, supersede, and create a run under a single
    /// exclusive lock so two concurrent starts cannot both insert a run
    /// (and both execute its actions) for the same workflow + subject.
    pub fn begin_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
        now: DateTime<Utc>,
    ) -> Result<BeginRunOutcome, CliError> {
        let workflow_id = run.workflow_id.clone();
        let subject_key = run.subject.key.clone();
        let fingerprint = run.subject_fingerprint.clone();
        let mut outcome: Option<BeginRunOutcome> = None;
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            reclaim_abandoned_runs(&mut document, &workflow_id, &subject_key, now);
            if let Some(existing) = document.runs.iter_mut().find(|candidate| {
                same_subject(candidate, &workflow_id, &subject_key)
                    && run_is_active(candidate, now)
                    && fingerprint_reusable(candidate, fingerprint.as_deref())
            }) {
                if matches!(trigger, PolicyRunTrigger::Manual) {
                    existing.nudge_manually();
                }
                outcome = Some(BeginRunOutcome::Existing(existing.clone()));
                return Ok(Some(document));
            }
            if fingerprint.is_some() {
                for stale in document.runs.iter_mut().filter(|candidate| {
                    same_subject(candidate, &workflow_id, &subject_key)
                        && run_is_active(candidate, now)
                        && candidate.subject_fingerprint != fingerprint
                }) {
                    stale.mark_cancelled("superseded by newer workflow subject state");
                }
            }
            document.runs.push(run.clone());
            outcome = Some(BeginRunOutcome::Created(run.clone()));
            Ok(Some(document))
        })?;
        outcome.ok_or_else(|| {
            CliErrorKind::workflow_parse("policy run begin produced no outcome".to_owned()).into()
        })
    }

    /// Atomically transition a `Waiting` run to `Running` so only one
    /// concurrent resume (timer or event) can take ownership of it. Returns
    /// `None` when the run is missing or no longer waiting.
    pub fn claim_waiting_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        let mut claimed: Option<PolicyWorkflowRun> = None;
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            if let Some(run) = document.runs.iter_mut().find(|run| run.run_id == run_id) {
                if run.status == PolicyRunStatus::Waiting {
                    run.mark_running(trigger);
                    claimed = Some(run.clone());
                }
            }
            Ok(Some(document))
        })?;
        Ok(claimed)
    }

    pub fn active_run(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        Ok(self
            .active_runs_for_subject(workflow_id, subject_key)?
            .into_iter()
            .next())
    }

    pub fn active_runs_for_subject(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        let mut runs = self
            .repository
            .load()?
            .unwrap_or_default()
            .runs
            .into_iter()
            .filter(|run| {
                run.workflow_id == workflow_id
                    && run.subject.key == subject_key
                    && matches!(
                        run.status,
                        PolicyRunStatus::Running | PolicyRunStatus::Waiting
                    )
            })
            .collect::<Vec<_>>();
        runs.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| right.created_at.cmp(&left.created_at))
        });
        Ok(runs)
    }

    pub fn run_by_id(&self, run_id: &str) -> Result<Option<PolicyWorkflowRun>, CliError> {
        Ok(self
            .repository
            .load()?
            .unwrap_or_default()
            .runs
            .into_iter()
            .find(|run| run.run_id == run_id))
    }

    pub fn runs_for_subject(
        &self,
        workflow_id: &str,
        subject_key: &str,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        let mut runs = self
            .repository
            .load()?
            .unwrap_or_default()
            .runs
            .into_iter()
            .filter(|run| run.workflow_id == workflow_id && run.subject.key == subject_key)
            .collect::<Vec<_>>();
        runs.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| right.created_at.cmp(&left.created_at))
        });
        Ok(runs)
    }

    pub fn runs_ready_for_event(
        &self,
        event: &PolicyWorkflowEvent,
    ) -> Result<Vec<String>, CliError> {
        Ok(self
            .repository
            .load()?
            .unwrap_or_default()
            .runs
            .into_iter()
            .filter(|run| run_matches_event(run, event))
            .map(|run| run.run_id)
            .collect())
    }

    pub fn runs_ready_for_timer(
        &self,
        now: DateTime<Utc>,
    ) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        let mut runs = Vec::new();
        for run in self.repository.load()?.unwrap_or_default().runs {
            if timer_wait_is_due(&run, &now)? {
                runs.push(run);
            }
        }
        runs.sort_by(|left, right| {
            left.updated_at
                .cmp(&right.updated_at)
                .then_with(|| left.created_at.cmp(&right.created_at))
        });
        Ok(runs)
    }
}

fn same_subject(run: &PolicyWorkflowRun, workflow_id: &str, subject_key: &str) -> bool {
    run.workflow_id == workflow_id && run.subject.key == subject_key
}

fn fingerprint_reusable(run: &PolicyWorkflowRun, fingerprint: Option<&str>) -> bool {
    match fingerprint {
        None => true,
        Some(fingerprint) => run.subject_fingerprint.as_deref() == Some(fingerprint),
    }
}

fn running_is_stale(run: &PolicyWorkflowRun, now: DateTime<Utc>) -> bool {
    DateTime::parse_from_rfc3339(&run.updated_at).is_ok_and(|updated_at| {
        now.signed_duration_since(updated_at.with_timezone(&Utc))
            .num_seconds()
            > STALE_RUNNING_SECONDS
    })
}

fn run_is_active(run: &PolicyWorkflowRun, now: DateTime<Utc>) -> bool {
    match run.status {
        PolicyRunStatus::Waiting => true,
        PolicyRunStatus::Running => !running_is_stale(run, now),
        PolicyRunStatus::Completed | PolicyRunStatus::Failed | PolicyRunStatus::Cancelled => false,
    }
}

fn reclaim_abandoned_runs(
    document: &mut PolicyWorkflowRunsDocument,
    workflow_id: &str,
    subject_key: &str,
    now: DateTime<Utc>,
) {
    for candidate in document.runs.iter_mut().filter(|candidate| {
        same_subject(candidate, workflow_id, subject_key)
            && candidate.status == PolicyRunStatus::Running
            && running_is_stale(candidate, now)
    }) {
        candidate.mark_cancelled("policy run reclaimed after the executor became unavailable");
    }
}
