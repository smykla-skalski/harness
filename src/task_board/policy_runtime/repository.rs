use std::path::PathBuf;

use crate::errors::CliError;
use crate::infra::persistence::versioned_json::VersionedJsonRepository;

use super::events::run_matches_event;
use super::models::{
    POLICY_WORKFLOW_RUNS_SCHEMA_VERSION, PolicyRunStatus, PolicyWorkflowEvent, PolicyWorkflowRun,
    PolicyWorkflowRunsDocument,
};

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
            if let Some(existing) = document.runs.iter_mut().find(|existing| existing.run_id == run.run_id)
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
            .repository
            .load()?
            .unwrap_or_default()
            .runs
            .into_iter()
            .find(|run| {
                run.workflow_id == workflow_id
                    && run.subject.key == subject_key
                    && matches!(run.status, PolicyRunStatus::Running | PolicyRunStatus::Waiting)
            }))
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
}
