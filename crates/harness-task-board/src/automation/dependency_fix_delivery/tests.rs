use std::sync::Mutex;

use super::*;

const BASE: &str = "0123456789abcdef0123456789abcdef01234567";
const LOCAL: &str = "123456789abcdef0123456789abcdef012345678";
const TREE: &str = "23456789abcdef0123456789abcdef0123456789";
const REMOTE: &str = "3456789abcdef0123456789abcdef0123456789a";

#[tokio::test]
async fn delivery_uses_frozen_fork_branch_and_records_verified_remote_head() {
    let client = Client::successful();
    let outcome = deliver_task_board_dependency_fix(&request(), &client)
        .await
        .expect("valid delivery");

    assert_eq!(
        outcome,
        TaskBoardDependencyFixDeliveryOutcome::Delivered {
            remote_head_revision: REMOTE.into()
        }
    );
    assert_eq!(
        client.published.lock().expect("published").clone(),
        Some((
            "contributor/widgets".into(),
            "renovate/serde".into(),
            "/isolated/fix".into(),
            BASE.into()
        ))
    );
    assert_eq!(
        client.recorded.lock().expect("recorded").as_deref(),
        Some(REMOTE)
    );
}

#[tokio::test]
async fn author_head_race_stops_before_publication() {
    let mut client = Client::successful();
    client.before.head.revision = REMOTE.into();

    assert_human_required(&client, TaskBoardDependencyFixDeliveryBlockReason::HeadRace).await;
    assert!(client.published.lock().expect("published").is_none());
}

#[tokio::test]
async fn changed_source_target_stops_before_publication() {
    let mut client = Client::successful();
    client.before.head.branch = "renovate/other".into();

    assert_human_required(
        &client,
        TaskBoardDependencyFixDeliveryBlockReason::PullRequestSourceChanged,
    )
    .await;
    assert!(client.published.lock().expect("published").is_none());
}

#[tokio::test]
async fn fork_permission_and_branch_failures_remain_explicit() {
    for reason in [
        TaskBoardDependencyFixDeliveryBlockReason::ForkAccessUnavailable,
        TaskBoardDependencyFixDeliveryBlockReason::PermissionDenied,
        TaskBoardDependencyFixDeliveryBlockReason::BranchUnavailable,
    ] {
        let mut client = Client::successful();
        client.publish_failure = Some(TaskBoardDependencyFixDeliveryFailure::new(
            reason,
            "publication refused",
        ));
        assert_human_required(&client, reason).await;
        assert!(client.recorded.lock().expect("recorded").is_none());
    }
}

#[tokio::test]
async fn post_publish_head_must_match_the_reviewed_tree() {
    let mut client = Client::successful();
    client.after.tree_revision = BASE.into();

    assert_human_required(
        &client,
        TaskBoardDependencyFixDeliveryBlockReason::RemoteHeadMismatch,
    )
    .await;
    assert!(client.recorded.lock().expect("recorded").is_none());
}

#[tokio::test]
async fn checkout_must_be_the_reported_descendant_of_the_frozen_head() {
    for mutate in [
        |evidence: &mut TaskBoardDependencyFixWorkingCopyEvidence| {
            evidence.head_revision = REMOTE.into();
        },
        |evidence: &mut TaskBoardDependencyFixWorkingCopyEvidence| {
            evidence.contains_base_revision = false;
        },
    ] {
        let mut client = Client::successful();
        mutate(&mut client.local);
        assert_human_required(
            &client,
            TaskBoardDependencyFixDeliveryBlockReason::IsolatedCheckoutUnavailable,
        )
        .await;
        assert!(client.published.lock().expect("published").is_none());
    }
}

#[tokio::test]
async fn blocked_fixer_requires_human_without_remote_reads_or_writes() {
    let client = Client::successful();
    let mut request = request();
    request.fix_result.head_revision = BASE.into();
    request.fix_result.changed_paths.clear();
    request.fix_result.validation.clear();
    request.fix_result.remaining_blockers = vec!["checkout is read-only".into()];

    let outcome = deliver_task_board_dependency_fix(&request, &client)
        .await
        .expect("valid blocked result");

    assert_eq!(
        outcome,
        TaskBoardDependencyFixDeliveryOutcome::HumanRequired(
            TaskBoardDependencyFixDeliveryFailure::new(
                TaskBoardDependencyFixDeliveryBlockReason::FixerBlocked,
                "checkout is read-only"
            )
        )
    );
    assert!(client.published.lock().expect("published").is_none());
    assert!(client.recorded.lock().expect("recorded").is_none());
}

#[tokio::test]
async fn recording_failure_never_reports_delivery() {
    let mut client = Client::successful();
    client.record_failure = Some(TaskBoardDependencyFixDeliveryFailure::new(
        TaskBoardDependencyFixDeliveryBlockReason::ResultRecordingFailed,
        "durable store unavailable",
    ));

    assert_human_required(
        &client,
        TaskBoardDependencyFixDeliveryBlockReason::ResultRecordingFailed,
    )
    .await;
}

async fn assert_human_required(
    client: &Client,
    expected: TaskBoardDependencyFixDeliveryBlockReason,
) {
    let outcome = deliver_task_board_dependency_fix(&request(), client)
        .await
        .expect("valid request");
    let TaskBoardDependencyFixDeliveryOutcome::HumanRequired(failure) = outcome else {
        panic!("expected human-required outcome");
    };
    assert_eq!(failure.reason, expected);
}

struct Client {
    local: TaskBoardDependencyFixWorkingCopyEvidence,
    before: TaskBoardDependencyFixRemoteHeadEvidence,
    after: TaskBoardDependencyFixRemoteHeadEvidence,
    publish_failure: Option<TaskBoardDependencyFixDeliveryFailure>,
    record_failure: Option<TaskBoardDependencyFixDeliveryFailure>,
    published: Mutex<Option<(String, String, String, String)>>,
    recorded: Mutex<Option<String>>,
}

impl Client {
    fn successful() -> Self {
        Self {
            local: TaskBoardDependencyFixWorkingCopyEvidence {
                head_revision: LOCAL.into(),
                tree_revision: TREE.into(),
                contains_base_revision: true,
            },
            before: remote_head(BASE, TREE),
            after: remote_head(REMOTE, TREE),
            publish_failure: None,
            record_failure: None,
            published: Mutex::new(None),
            recorded: Mutex::new(None),
        }
    }
}

#[async_trait]
impl TaskBoardDependencyFixDeliveryClient for Client {
    async fn working_copy_evidence(
        &self,
        worktree: &str,
        base_head_revision: &str,
    ) -> Result<TaskBoardDependencyFixWorkingCopyEvidence, TaskBoardDependencyFixDeliveryFailure>
    {
        assert_eq!(worktree, "/isolated/fix");
        assert_eq!(base_head_revision, BASE);
        Ok(self.local.clone())
    }

    async fn pull_request_head(
        &self,
        repository: &str,
        pull_request_number: u64,
    ) -> Result<TaskBoardDependencyFixRemoteHeadEvidence, TaskBoardDependencyFixDeliveryFailure>
    {
        assert_eq!(repository, "upstream/widgets");
        assert_eq!(pull_request_number, 17);
        if self.published.lock().expect("published").is_some() {
            Ok(self.after.clone())
        } else {
            Ok(self.before.clone())
        }
    }

    async fn publish_source_branch(
        &self,
        source_repository: &str,
        source_branch: &str,
        worktree: &str,
        expected_head_revision: &str,
    ) -> Result<(), TaskBoardDependencyFixDeliveryFailure> {
        if let Some(failure) = &self.publish_failure {
            return Err(failure.clone());
        }
        *self.published.lock().expect("published") = Some((
            source_repository.into(),
            source_branch.into(),
            worktree.into(),
            expected_head_revision.into(),
        ));
        Ok(())
    }

    async fn record_remote_head(
        &self,
        _request: &TaskBoardDependencyFixDeliveryRequest,
        remote_head_revision: &str,
    ) -> Result<(), TaskBoardDependencyFixDeliveryFailure> {
        if let Some(failure) = &self.record_failure {
            return Err(failure.clone());
        }
        *self.recorded.lock().expect("recorded") = Some(remote_head_revision.into());
        Ok(())
    }
}

fn request() -> TaskBoardDependencyFixDeliveryRequest {
    TaskBoardDependencyFixDeliveryRequest {
        pull_request: TaskBoardPullRequestIdentity {
            repository: "upstream/widgets".into(),
            number: 17,
            head: Some(TaskBoardPullRequestHeadIdentity {
                repository: "contributor/widgets".into(),
                branch: "renovate/serde".into(),
                revision: BASE.into(),
            }),
        },
        worktree: "/isolated/fix".into(),
        fix_result: TaskBoardDependencyFixResult {
            schema_version: 1,
            dispatch_id: "route-1:fix".into(),
            route_id: "route-1".into(),
            base_head_revision: BASE.into(),
            head_revision: LOCAL.into(),
            summary: "repair the failing build".into(),
            changed_paths: vec!["src/lib.rs".into()],
            validation: vec!["mise run test:unit".into()],
            remaining_blockers: Vec::new(),
        },
    }
}

fn remote_head(revision: &str, tree_revision: &str) -> TaskBoardDependencyFixRemoteHeadEvidence {
    TaskBoardDependencyFixRemoteHeadEvidence {
        head: TaskBoardPullRequestHeadIdentity {
            repository: "contributor/widgets".into(),
            branch: "renovate/serde".into(),
            revision: revision.into(),
        },
        tree_revision: tree_revision.into(),
    }
}
