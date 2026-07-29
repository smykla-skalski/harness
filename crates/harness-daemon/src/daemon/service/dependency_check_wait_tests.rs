use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use harness_kernel::errors::CliError;

use super::dependency_check_wait::spawn_dependency_check_wait;
use crate::task_board::github::{
    CheckGate, CheckState, Mergeability, PullRequestEvidence, PullRequestEvidenceRead,
    PullRequestEvidenceSource, PullRequestIdentity, PullRequestLifecycle, PullRequestMergeGates,
    ReviewDecision, ReviewGate,
};
use crate::task_board::{
    TaskBoardDependencyCheckResumeAdmission, TaskBoardDependencyCheckResumeRecord,
    TaskBoardDependencyCheckResumeSink, TaskBoardDependencyCheckResumeStatus,
    TaskBoardDependencyCheckWait,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[tokio::test]
async fn daemon_observer_resumes_once_without_monitor_state() {
    let sink = Arc::new(Sink::default());
    let first = spawn_dependency_check_wait(
        Arc::new(Source),
        wait(),
        1,
        Duration::ZERO,
        Arc::new(AtomicBool::new(false)),
        sink.clone(),
    )
    .await
    .expect("observer task")
    .expect("first resume");
    let replay = spawn_dependency_check_wait(
        Arc::new(Source),
        wait(),
        1,
        Duration::ZERO,
        Arc::new(AtomicBool::new(false)),
        sink.clone(),
    )
    .await
    .expect("replay task")
    .expect("duplicate resume");

    assert!(first.created);
    assert!(!replay.created);
    assert_eq!(sink.transitions(), 1);
    assert!(matches!(
        first.record.status,
        TaskBoardDependencyCheckResumeStatus::ChecksFailed { .. }
    ));
}

#[derive(Default)]
struct Sink {
    record: Mutex<Option<TaskBoardDependencyCheckResumeRecord>>,
    transitions: Mutex<usize>,
}

impl Sink {
    fn transitions(&self) -> usize {
        *self
            .transitions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

#[async_trait]
impl TaskBoardDependencyCheckResumeSink for Sink {
    async fn resume_once(
        &self,
        record: TaskBoardDependencyCheckResumeRecord,
    ) -> Result<TaskBoardDependencyCheckResumeAdmission, CliError> {
        let mut stored = self.record.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = &*stored {
            return Ok(TaskBoardDependencyCheckResumeAdmission::Duplicate(
                Box::new(existing.clone()),
            ));
        }
        *stored = Some(record);
        *self
            .transitions
            .lock()
            .unwrap_or_else(PoisonError::into_inner) += 1;
        Ok(TaskBoardDependencyCheckResumeAdmission::Resumed)
    }
}

struct Source;

#[async_trait]
impl PullRequestEvidenceSource for Source {
    async fn read_pull_request_evidence(
        &self,
        identity: &PullRequestIdentity,
    ) -> Result<PullRequestEvidenceRead, CliError> {
        Ok(PullRequestEvidenceRead::found(PullRequestEvidence {
            identity: identity.clone(),
            head_revision: HEAD.into(),
            author: Some("renovate".into()),
            lifecycle: PullRequestLifecycle::Open,
            is_draft: false,
            gates: PullRequestMergeGates {
                mergeability: Mergeability::Mergeable,
                viewer_can_update: true,
                viewer_can_merge_as_admin: false,
                checks: vec![CheckGate {
                    name: "build".into(),
                    state: CheckState::Failure,
                    details_url: Some("https://checks/build".into()),
                }],
                required_check_names: vec!["build".into()],
                review: ReviewGate {
                    decision: ReviewDecision::Approved,
                    current_approvals: 1,
                    required_approvals: 1,
                },
            },
            observed_at: "2026-07-29T00:00:00Z".into(),
        }))
    }
}

fn wait() -> TaskBoardDependencyCheckWait {
    TaskBoardDependencyCheckWait {
        resume_id: "dependency-triage:sha256:test:checks".into(),
        route_id: "dependency-triage:sha256:test".into(),
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: HEAD.into(),
        required_checks: vec!["build".into()],
    }
}
