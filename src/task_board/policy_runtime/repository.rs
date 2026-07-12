use std::collections::HashMap;
#[cfg(test)]
use std::path::PathBuf;

use chrono::{DateTime, Utc};

#[cfg(test)]
use crate::errors::{CliError, CliErrorKind};
#[cfg(test)]
use crate::infra::persistence::versioned_json::VersionedJsonRepository;

#[cfg(test)]
use super::events::run_matches_event;
#[cfg(test)]
use super::models::{POLICY_WORKFLOW_RUNS_SCHEMA_VERSION, PolicyWorkflowEvent};
use super::models::{
    PolicyRunStatus, PolicyRunTrigger, PolicyWorkflowRun, PolicyWorkflowRunsDocument,
};
#[cfg(test)]
use super::scheduler::timer_wait_is_due;

/// A `Running` run whose `updated_at` is older than this is treated as
/// abandoned (its executor crashed or was killed), so a new run may take
/// over instead of being blocked forever by a stuck record.
const STALE_RUNNING_SECONDS: i64 = 600;

/// How many terminal (completed/failed/cancelled) runs to retain per
/// workflow + subject. Bounds the runs document so it cannot grow without
/// limit as Auto is pressed repeatedly; active runs are never pruned.
const TERMINAL_RUN_RETENTION_PER_SUBJECT: usize = 10;

/// Outcome of atomically beginning a policy workflow run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BeginRunOutcome {
    /// A fresh run was inserted and should be executed by the caller.
    Created(PolicyWorkflowRun),
    /// A live run already existed for this workflow + subject; reuse it.
    Existing(PolicyWorkflowRun),
}

#[cfg(test)]
pub struct PolicyRuntimeRepository {
    repository: VersionedJsonRepository<PolicyWorkflowRunsDocument>,
}

#[cfg(test)]
impl PolicyRuntimeRepository {
    #[must_use]
    pub fn new(mut root: PathBuf) -> Self {
        // Consume `root` in place so callers keep passing an owned `PathBuf`
        // (no signature ripple) while the value is genuinely moved, not just
        // borrowed for a `join`.
        root.push("policy-workflow-runs-v1.json");
        Self {
            repository: VersionedJsonRepository::new(root, POLICY_WORKFLOW_RUNS_SCHEMA_VERSION),
        }
    }

    /// Insert or replace `run` in the persisted runs document.
    ///
    /// # Errors
    /// Returns `CliError` when the underlying versioned-JSON repository fails
    /// to load, serialize, or write the runs document.
    pub fn save(&self, run: &PolicyWorkflowRun) -> Result<(), CliError> {
        let run = run.clone();
        let _ = self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            save_run_in_document(&mut document, &run);
            Ok(Some(document))
        })?;
        Ok(())
    }

    /// Atomically dedupe, supersede, and create a run under a single
    /// exclusive lock so two concurrent starts cannot both insert a run
    /// (and both execute its actions) for the same workflow + subject.
    ///
    /// # Errors
    /// Returns `CliError` when the versioned-JSON repository fails to load,
    /// serialize, or write the runs document, or when the update produced no
    /// outcome.
    pub fn begin_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
        now: DateTime<Utc>,
    ) -> Result<BeginRunOutcome, CliError> {
        let mut outcome: Option<BeginRunOutcome> = None;
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            outcome = Some(begin_run_in_document(&mut document, run, trigger, now));
            Ok(Some(document))
        })?;
        outcome.ok_or_else(|| {
            CliErrorKind::workflow_parse("policy run begin produced no outcome".to_owned()).into()
        })
    }

    /// Atomically transition a `Waiting` run to `Running` so only one
    /// concurrent resume (timer or event) can take ownership of it. Returns
    /// `None` when the run is missing or no longer waiting.
    ///
    /// # Errors
    /// Returns `CliError` when the versioned-JSON repository fails to load,
    /// serialize, or write the runs document.
    pub fn claim_waiting_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        let mut claimed: Option<PolicyWorkflowRun> = None;
        self.repository.update(|current| {
            let mut document = current.unwrap_or_default();
            claimed = claim_waiting_run_in_document(&mut document, run_id, trigger);
            Ok(Some(document))
        })?;
        Ok(claimed)
    }

    /// Return the newest active (Running/Waiting) run for the workflow +
    /// subject, if any.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded.
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

    /// Return all active (Running/Waiting) runs for the workflow + subject,
    /// newest first by `updated_at` then `created_at`.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded.
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

    /// Load every persisted run, newest first by `updated_at` then
    /// `created_at`. Backs the cross-subject observability summary so the
    /// daemon can report run totals without scanning per-subject queries.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded.
    pub fn list_runs(&self) -> Result<Vec<PolicyWorkflowRun>, CliError> {
        let mut runs = self.repository.load()?.unwrap_or_default().runs;
        runs.sort_by(|left, right| {
            right
                .updated_at
                .cmp(&left.updated_at)
                .then_with(|| right.created_at.cmp(&left.created_at))
        });
        Ok(runs)
    }

    /// Return the run with the given `run_id`, if it exists.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded.
    pub fn run_by_id(&self, run_id: &str) -> Result<Option<PolicyWorkflowRun>, CliError> {
        Ok(self
            .repository
            .load()?
            .unwrap_or_default()
            .runs
            .into_iter()
            .find(|run| run.run_id == run_id))
    }

    /// Return every run for the workflow + subject, newest first by
    /// `updated_at` then `created_at`.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded.
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

    /// Return the ids of runs whose pending wait matches `event`.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded.
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

    /// Return the runs whose timer wait is due as of `now`, oldest first by
    /// `updated_at` then `created_at`.
    ///
    /// # Errors
    /// Returns `CliError` when the runs document cannot be loaded or a wait
    /// timestamp cannot be parsed.
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

pub(crate) fn save_run_in_document(
    document: &mut PolicyWorkflowRunsDocument,
    run: &PolicyWorkflowRun,
) {
    if let Some(existing) = document
        .runs
        .iter_mut()
        .find(|existing| existing.run_id == run.run_id)
    {
        existing.clone_from(run);
    } else {
        document.runs.push(run.clone());
    }
}

pub(crate) fn begin_run_in_document(
    document: &mut PolicyWorkflowRunsDocument,
    run: PolicyWorkflowRun,
    trigger: PolicyRunTrigger,
    now: DateTime<Utc>,
) -> BeginRunOutcome {
    let workflow_id = run.workflow_id.clone();
    let subject_key = run.subject.key.clone();
    let fingerprint = run.subject_fingerprint.clone();
    reclaim_abandoned_runs(document, &workflow_id, &subject_key, now);
    if let Some(existing) = document.runs.iter_mut().find(|candidate| {
        same_subject(candidate, &workflow_id, &subject_key)
            && run_is_active(candidate, now)
            && fingerprint_reusable(candidate, fingerprint.as_deref())
    }) {
        if matches!(trigger, PolicyRunTrigger::Manual) {
            existing.nudge_manually();
        }
        return BeginRunOutcome::Existing(existing.clone());
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
    let outcome = BeginRunOutcome::Created(run.clone());
    document.runs.push(run);
    prune_terminal_runs(document);
    outcome
}

pub(crate) fn claim_waiting_run_in_document(
    document: &mut PolicyWorkflowRunsDocument,
    run_id: &str,
    trigger: PolicyRunTrigger,
) -> Option<PolicyWorkflowRun> {
    let run = document
        .runs
        .iter_mut()
        .find(|run| run.run_id == run_id && run.status == PolicyRunStatus::Waiting)?;
    run.mark_running(trigger);
    Some(run.clone())
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

fn is_terminal(status: PolicyRunStatus) -> bool {
    matches!(
        status,
        PolicyRunStatus::Completed | PolicyRunStatus::Failed | PolicyRunStatus::Cancelled
    )
}

/// Drop the oldest terminal runs per workflow + subject beyond the retention
/// cap. Active runs (Running/Waiting) are always kept.
fn prune_terminal_runs(document: &mut PolicyWorkflowRunsDocument) {
    let mut order: Vec<usize> = (0..document.runs.len()).collect();
    // Newest first by created_at so retention keeps the most recent runs.
    order.sort_by(|&left, &right| {
        document.runs[right]
            .created_at
            .cmp(&document.runs[left].created_at)
    });
    let mut kept_terminal: HashMap<(String, String), usize> = HashMap::new();
    let mut keep = vec![false; document.runs.len()];
    for index in order {
        let run = &document.runs[index];
        if !is_terminal(run.status) {
            keep[index] = true;
            continue;
        }
        let key = (run.workflow_id.clone(), run.subject.key.clone());
        let count = kept_terminal.entry(key).or_insert(0);
        if *count < TERMINAL_RUN_RETENTION_PER_SUBJECT {
            *count += 1;
            keep[index] = true;
        }
    }
    let mut index = 0;
    document.runs.retain(|_| {
        let keep_run = keep[index];
        index += 1;
        keep_run
    });
}
