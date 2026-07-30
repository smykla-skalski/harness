use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};

use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::*;
use crate::TaskBoardDependencyReverificationDecision;
use crate::github::{
    CheckGate, CheckState, GitHubMergeEvidence, GitHubPullRequestHandle, Mergeability,
    PullRequestActionStore, PullRequestEvidenceRead, PullRequestMergeGates, ReviewDecision,
    ReviewGate,
};

pub(super) const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const MOVED_HEAD: &str = "123456789abcdef0123456789abcdef012345678";

pub(super) struct FakeClient {
    evidence: Mutex<VecDeque<PullRequestEvidence>>,
    pub(super) reads: AtomicUsize,
    pub(super) approvals: AtomicUsize,
    pub(super) merges: AtomicUsize,
    fail_approval_once: AtomicBool,
    last_merge: Mutex<Option<(GitHubMergeMethod, String)>>,
}

impl FakeClient {
    pub(super) fn new(evidence: impl IntoIterator<Item = PullRequestEvidence>) -> Self {
        Self {
            evidence: Mutex::new(evidence.into_iter().collect()),
            reads: AtomicUsize::new(0),
            approvals: AtomicUsize::new(0),
            merges: AtomicUsize::new(0),
            fail_approval_once: AtomicBool::new(false),
            last_merge: Mutex::new(None),
        }
    }

    pub(super) fn with_approval_failure(self) -> Self {
        self.fail_approval_once.store(true, Ordering::SeqCst);
        self
    }

    pub(super) fn last_merge(&self) -> Option<(GitHubMergeMethod, String)> {
        self.last_merge
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    fn next_evidence(&self) -> PullRequestEvidence {
        let mut evidence = self.evidence.lock().unwrap_or_else(PoisonError::into_inner);
        if evidence.len() > 1 {
            evidence.pop_front().expect("seeded evidence")
        } else {
            evidence.front().expect("seeded evidence").clone()
        }
    }
}

#[async_trait]
impl GitHubAutomationClient for FakeClient {
    async fn pull_request_merge_evidence(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubMergeEvidence, CliError> {
        Err(CliErrorKind::workflow_io("unused merge evidence").into())
    }

    async fn read_pull_request_evidence(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<PullRequestEvidenceRead, CliError> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        Ok(PullRequestEvidenceRead::found(self.next_evidence()))
    }

    async fn get_pull_request_fresh(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
    ) -> Result<GitHubPullRequestHandle, CliError> {
        Err(CliErrorKind::workflow_io("unused pull request handle").into())
    }

    async fn approve_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        _head_revision: &str,
    ) -> Result<(), CliError> {
        self.approvals.fetch_add(1, Ordering::SeqCst);
        if self.fail_approval_once.swap(false, Ordering::SeqCst) {
            return Err(CliErrorKind::workflow_io("approval response lost").into());
        }
        Ok(())
    }

    async fn merge_pull_request(
        &self,
        _config: &GitHubProjectConfig,
        _pull_request_number: u64,
        method: GitHubMergeMethod,
        head_sha: Option<&str>,
    ) -> Result<(), CliError> {
        self.merges.fetch_add(1, Ordering::SeqCst);
        *self
            .last_merge
            .lock()
            .unwrap_or_else(PoisonError::into_inner) =
            Some((method, head_sha.unwrap_or_default().to_owned()));
        Ok(())
    }
}

#[derive(Default)]
pub(super) struct MemorySink {
    records: Mutex<Vec<TaskBoardDependencyCompletionRecord>>,
}

#[async_trait]
impl TaskBoardDependencyCompletionSink for MemorySink {
    async fn record(&self, record: &TaskBoardDependencyCompletionRecord) -> Result<(), CliError> {
        let mut records = self.records.lock().unwrap_or_else(PoisonError::into_inner);
        if records.last() != Some(record) {
            records.push(record.clone());
        }
        Ok(())
    }
}

pub(super) async fn run(
    client: &FakeClient,
    store: &dyn PullRequestActionStore,
    sink: &MemorySink,
    request: TaskBoardDependencyCompletionRequest,
    policy: TaskBoardDependencyCompletionPolicy,
) -> Result<TaskBoardDependencyCompletionOutcome, CliError> {
    complete_task_board_dependency_pull_request(&request, &policy, &config(), client, store, sink)
        .await
}

pub(super) fn request() -> TaskBoardDependencyCompletionRequest {
    TaskBoardDependencyCompletionRequest {
        route_id: "route-1".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        verified_head_revision: HEAD.into(),
        reverification: TaskBoardDependencyReverificationResult {
            schema_version:
                super::super::super::TASK_BOARD_DEPENDENCY_REVERIFICATION_SCHEMA_VERSION,
            verification_id: format!("route-1:verify:{HEAD}"),
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            exact_head_revision: HEAD.into(),
            decision: TaskBoardDependencyReverificationDecision::GreenLight,
            reasoning: "verified".into(),
            repair_instructions: Vec::new(),
        },
        merge_method: GitHubMergeMethod::Squash,
    }
}

pub(super) fn policy(automated_approval_allowed: bool) -> TaskBoardDependencyCompletionPolicy {
    TaskBoardDependencyCompletionPolicy {
        automated_approval_allowed,
        allowed_merge_methods: vec![GitHubMergeMethod::Squash],
    }
}

fn config() -> GitHubProjectConfig {
    GitHubProjectConfig::new("acme", "widgets")
}

pub(super) fn evidence(current: u32, required: u32) -> PullRequestEvidence {
    PullRequestEvidence {
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        head_revision: HEAD.into(),
        author: Some("renovate".into()),
        viewer_login: Some("harness-bot".into()),
        viewer_has_approved: false,
        lifecycle: PullRequestLifecycle::Open,
        is_draft: false,
        gates: green_gates(current, required),
        observed_at: "2026-07-30T00:00:00Z".into(),
    }
}

pub(super) fn approved_by_viewer(current: u32, required: u32) -> PullRequestEvidence {
    let mut evidence = evidence(current, required);
    evidence.viewer_has_approved = true;
    evidence
}

pub(super) fn self_authored(current: u32, required: u32) -> PullRequestEvidence {
    let mut evidence = evidence(current, required);
    evidence.author.clone_from(&evidence.viewer_login);
    evidence
}

pub(super) fn moved_head() -> PullRequestEvidence {
    let mut evidence = approved_by_viewer(1, 1);
    evidence.head_revision = MOVED_HEAD.into();
    evidence
}

pub(super) fn conflicted() -> PullRequestEvidence {
    let mut evidence = evidence(1, 1);
    evidence.gates.mergeability = Mergeability::Conflicting;
    evidence
}

pub(super) fn changes_requested() -> PullRequestEvidence {
    let mut evidence = evidence(0, 1);
    evidence.gates.review.decision = ReviewDecision::ChangesRequested;
    evidence
}

pub(super) fn without_permission() -> PullRequestEvidence {
    let mut evidence = evidence(1, 1);
    evidence.gates.viewer_can_update = false;
    evidence.gates.viewer_can_merge_as_admin = false;
    evidence
}

pub(super) fn green_gates(current: u32, required: u32) -> PullRequestMergeGates {
    PullRequestMergeGates {
        mergeability: Mergeability::Mergeable,
        viewer_can_update: true,
        viewer_can_merge_as_admin: false,
        checks: vec![CheckGate {
            name: "build".into(),
            state: CheckState::Success,
            details_url: None,
        }],
        required_check_names: vec!["build".into()],
        review: ReviewGate {
            decision: if current >= required && required > 0 {
                ReviewDecision::Approved
            } else {
                ReviewDecision::ReviewRequired
            },
            current_approvals: current,
            required_approvals: required,
        },
    }
}
