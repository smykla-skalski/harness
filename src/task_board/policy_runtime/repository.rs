use std::path::PathBuf;

use chrono::{DateTime, Utc};

use crate::errors::CliError;
use crate::infra::persistence::versioned_json::VersionedJsonRepository;

use super::events::run_matches_event;
use super::models::{
    POLICY_WORKFLOW_RUNS_SCHEMA_VERSION, PolicyRunStatus, PolicyWorkflowEvent, PolicyWorkflowRun,
    PolicyWorkflowRunsDocument,
};
use super::scheduler::timer_wait_is_due;

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
