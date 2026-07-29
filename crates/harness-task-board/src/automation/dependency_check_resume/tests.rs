use std::collections::VecDeque;
use std::sync::atomic::AtomicBool;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use super::*;
use crate::github::{
    CheckGate, Mergeability, PullRequestEvidenceRead, PullRequestLifecycle, PullRequestMergeGates,
    ReviewDecision, ReviewGate,
};
use crate::{
    TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION, TaskBoardDependencyApprovalEvidence,
    TaskBoardDependencyCheck, TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
    TaskBoardDependencyConflictState, TaskBoardDependencyIdentity,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[tokio::test]
async fn successful_checks_resume_exactly_once() {
    let route = waiting_route();
    let initial = evidence(CheckState::Pending, None);
    let wait = task_board_dependency_check_wait(&route, &initial).expect("check wait");
    let source = Source::new(vec![
        found(evidence(CheckState::Pending, None)),
        found(evidence(CheckState::Success, Some("https://checks/build"))),
    ]);
    let sink = Sink::default();

    let first = observe(&source, &wait, &sink).await.expect("first resume");
    let replay_source = Source::new(vec![found(evidence(
        CheckState::Success,
        Some("https://checks/build"),
    ))]);
    let replay = observe(&replay_source, &wait, &sink)
        .await
        .expect("duplicate resume");

    assert!(first.created);
    assert!(!replay.created);
    assert_eq!(sink.transitions(), 1);
    assert_eq!(first.record, replay.record);
    assert_eq!(
        first.record.status,
        TaskBoardDependencyCheckResumeStatus::ChecksPassed {
            checks: vec![settled(
                "build",
                TaskBoardDependencyCheckConclusion::Success,
                Some("https://checks/build")
            )]
        }
    );
}

#[tokio::test]
async fn failed_checks_resume_with_names_conclusions_and_links() {
    let wait =
        task_board_dependency_check_wait(&waiting_route(), &evidence(CheckState::Pending, None))
            .expect("check wait");
    let source = Source::new(vec![found(evidence(
        CheckState::Failure,
        Some("https://checks/build"),
    ))]);
    let sink = Sink::default();

    let outcome = observe(&source, &wait, &sink).await.expect("failed resume");

    assert_eq!(
        outcome.record.status,
        TaskBoardDependencyCheckResumeStatus::ChecksFailed {
            checks: vec![settled(
                "build",
                TaskBoardDependencyCheckConclusion::Failure,
                Some("https://checks/build")
            )]
        }
    );
}

#[test]
fn failed_outcomes_preserve_the_complete_required_check_set() {
    let mut settled_evidence = evidence(CheckState::Failure, Some("https://checks/build"));
    settled_evidence.gates.checks.push(CheckGate {
        name: "lint".into(),
        state: CheckState::Success,
        details_url: Some("https://checks/lint".into()),
    });

    assert_eq!(
        settled_status(&settled_evidence, &["build".into(), "lint".into()]).expect("settled"),
        TaskBoardDependencyCheckResumeStatus::ChecksFailed {
            checks: vec![
                settled(
                    "build",
                    TaskBoardDependencyCheckConclusion::Failure,
                    Some("https://checks/build")
                ),
                settled(
                    "lint",
                    TaskBoardDependencyCheckConclusion::Success,
                    Some("https://checks/lint")
                )
            ]
        }
    );
}

#[test]
fn pending_checks_cannot_be_recorded_as_terminal_conclusions() {
    let error = settled_status(&evidence(CheckState::Pending, None), &["build".into()])
        .expect_err("pending check must not settle");

    assert!(error.to_string().contains("still pending"));
}

#[tokio::test]
async fn timeout_cancellation_and_changed_head_stay_distinct() {
    let wait =
        task_board_dependency_check_wait(&waiting_route(), &evidence(CheckState::Pending, None))
            .expect("check wait");
    let timeout = observe(
        &Source::new(vec![
            found(evidence(CheckState::Pending, None)),
            found(evidence(CheckState::Pending, None)),
        ]),
        &wait,
        &Sink::default(),
    )
    .await
    .expect("timeout");
    assert_eq!(
        timeout.record.status,
        TaskBoardDependencyCheckResumeStatus::TimedOut
    );

    let cancel = AtomicBool::new(true);
    let cancelled = observe_with_cancel(&Source::new(Vec::new()), &wait, &Sink::default(), &cancel)
        .await
        .expect("cancelled");
    assert_eq!(
        cancelled.record.status,
        TaskBoardDependencyCheckResumeStatus::Cancelled
    );

    let mut changed = evidence(CheckState::Success, None);
    changed.head_revision = "abcdefabcdefabcdefabcdefabcdefabcdefabcd".into();
    let superseded = observe(&Source::new(vec![found(changed)]), &wait, &Sink::default())
        .await
        .expect("changed head");
    assert_eq!(
        superseded.record.status,
        TaskBoardDependencyCheckResumeStatus::HeadChanged {
            observed_head: "abcdefabcdefabcdefabcdefabcdefabcdefabcd".into()
        }
    );
}

#[test]
fn only_waiting_routes_can_start_an_observer() {
    let mut route = waiting_route();
    route.status = TaskBoardDependencyRouteStatus::ReadyToContinue;

    assert!(
        task_board_dependency_check_wait(&route, &evidence(CheckState::Pending, None))
            .expect_err("non-wait route")
            .to_string()
            .contains("not waiting")
    );

    let route = waiting_route();
    let mut unrelated = evidence(CheckState::Pending, None);
    unrelated.gates.required_check_names = vec!["lint".into()];
    assert!(
        task_board_dependency_check_wait(&route, &unrelated)
            .expect_err("model check must be required")
            .to_string()
            .contains("incomplete exact-head evidence")
    );
}

#[test]
fn required_checks_can_start_waiting_before_their_rollup_appears() {
    let mut initial = evidence(CheckState::Pending, None);
    initial.gates.checks.clear();

    let wait = task_board_dependency_check_wait(&waiting_route(), &initial)
        .expect("missing required check remains pending");

    assert_eq!(wait.required_checks, vec!["build"]);
}

async fn observe(
    source: &Source,
    wait: &TaskBoardDependencyCheckWait,
    sink: &Sink,
) -> Result<TaskBoardDependencyCheckResumeOutcome, CliError> {
    observe_with_cancel(source, wait, sink, &AtomicBool::new(false)).await
}

async fn observe_with_cancel(
    source: &Source,
    wait: &TaskBoardDependencyCheckWait,
    sink: &Sink,
    cancel: &AtomicBool,
) -> Result<TaskBoardDependencyCheckResumeOutcome, CliError> {
    observe_task_board_dependency_check_wait(
        source,
        wait,
        CheckWaitControls {
            max_polls: 2,
            poll_interval: Duration::ZERO,
            cancel,
        },
        sink,
    )
    .await
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

struct Source {
    reads: Mutex<VecDeque<PullRequestEvidenceRead>>,
}

impl Source {
    fn new(reads: Vec<PullRequestEvidenceRead>) -> Self {
        Self {
            reads: Mutex::new(reads.into()),
        }
    }

    fn reads(&self) -> MutexGuard<'_, VecDeque<PullRequestEvidenceRead>> {
        self.reads.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[async_trait]
impl PullRequestEvidenceSource for Source {
    async fn read_pull_request_evidence(
        &self,
        _identity: &PullRequestIdentity,
    ) -> Result<PullRequestEvidenceRead, CliError> {
        self.reads()
            .pop_front()
            .ok_or_else(|| CliErrorKind::workflow_io("no seeded read").into())
    }
}

fn waiting_route() -> TaskBoardDependencyRouteRecord {
    TaskBoardDependencyRouteRecord {
        route_id: "dependency-triage:sha256:test".into(),
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD.into(),
        status: TaskBoardDependencyRouteStatus::WaitingForChecks {
            pending_checks: vec!["build".into()],
        },
        reason: "build is pending".into(),
        source_result: waiting_result(),
    }
}

fn waiting_result() -> TaskBoardDependencyTriageResult {
    TaskBoardDependencyTriageResult {
        schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD.into(),
        dependency: TaskBoardDependencyIdentity {
            name: "serde".into(),
            ecosystem: "cargo".into(),
            current_version: "1.0.0".into(),
            target_version: "1.0.1".into(),
            update_class: TaskBoardDependencyUpdateClass::Patch,
        },
        checks: vec![TaskBoardDependencyCheck {
            name: "build".into(),
            state: TaskBoardDependencyCheckState::Pending,
            details_url: Some("https://checks/build".into()),
        }],
        conflicts: TaskBoardDependencyConflictEvidence {
            state: TaskBoardDependencyConflictState::Clean,
            summary: "clean".into(),
        },
        approvals: TaskBoardDependencyApprovalEvidence {
            current: 1,
            required: 1,
        },
        safety_assumption: "current evidence is complete".into(),
        disposition: TaskBoardDependencyTriageDisposition::WaitForChecks,
        required_tools: vec!["task_board.audit".into(), "github.read".into()],
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain source result".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: "wait_for_checks".into(),
                reason: "build is pending".into(),
            },
        ],
    }
}

fn evidence(state: CheckState, details_url: Option<&str>) -> PullRequestEvidence {
    PullRequestEvidence {
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
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
                state,
                details_url: details_url.map(str::to_owned),
            }],
            required_check_names: vec!["build".into()],
            review: ReviewGate {
                decision: ReviewDecision::Approved,
                current_approvals: 1,
                required_approvals: 1,
            },
        },
        observed_at: "2026-07-29T00:00:00Z".into(),
    }
}

fn found(evidence: PullRequestEvidence) -> PullRequestEvidenceRead {
    PullRequestEvidenceRead::found(evidence)
}

fn settled(
    name: &str,
    conclusion: TaskBoardDependencyCheckConclusion,
    details_url: Option<&str>,
) -> TaskBoardDependencySettledCheck {
    TaskBoardDependencySettledCheck {
        name: name.into(),
        conclusion,
        details_url: details_url.map(str::to_owned),
    }
}
