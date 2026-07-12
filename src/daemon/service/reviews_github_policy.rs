use crate::daemon::{db::DaemonDb, state};
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::policy::review_target_policy_evidence;
use crate::reviews::{
    ReviewTarget, ReviewsApproveRequest, ReviewsApproveRequestSource, ReviewsFileCommentRequest,
};
use crate::task_board::policy_graph::{RecordedPolicyDecision, record_policy_decision};
use crate::task_board::{
    PolicyAction, PolicyDecision, PolicyEvidence, PolicyGraph, PolicyGraphMode,
    PolicyGraphNodeKind, PolicyInput, PolicyReasonCode, PolicySubject,
};

const REVIEW_APPROVE_ACTION_ID: &str = "reviews.approve";
const REVIEW_TEXT_PASTE_APPROVE_ACTION: &str = "approveReviewPullRequests";

#[derive(Debug, Clone, Copy)]
enum ReviewsPolicyInputRequirement {
    None,
    ReviewTextPasteApproves,
}

struct EnforcedReviewsPolicy {
    canvas_id: String,
    document: PolicyGraph,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum ReviewsGitHubMutation {
    Approve,
    Comment,
    FileComment,
    Merge,
    RerunChecks,
    AddLabel,
    RequestReview,
    BodyUpdate,
    FilesViewed,
    ReviewThreadResolve,
}

impl ReviewsGitHubMutation {
    const fn label(self) -> &'static str {
        match self {
            Self::Approve => "approve",
            Self::Comment => "comment",
            Self::FileComment => "file comment",
            Self::Merge => "merge",
            Self::RerunChecks => "rerun checks",
            Self::AddLabel => "add label",
            Self::RequestReview => "request review",
            Self::BodyUpdate => "update body",
            Self::FilesViewed => "update file viewed state",
            Self::ReviewThreadResolve => "resolve review thread",
        }
    }

    const fn policy_action(self) -> PolicyAction {
        match self {
            Self::Approve
            | Self::Comment
            | Self::FileComment
            | Self::RequestReview
            | Self::FilesViewed
            | Self::ReviewThreadResolve => PolicyAction::SubmitReview,
            Self::Merge => PolicyAction::MergePr,
            Self::RerunChecks => PolicyAction::Sync,
            Self::AddLabel | Self::BodyUpdate => PolicyAction::Triage,
        }
    }
}

pub(crate) fn enforce_review_targets_policy(
    mutation: ReviewsGitHubMutation,
    targets: &[ReviewTarget],
) -> Result<(), CliError> {
    let entry = enforced_reviews_github_policy_entry(mutation)?;
    for target in targets {
        let input = PolicyInput {
            workflow: None,
            action: mutation.policy_action(),
            subject: PolicySubject {
                repository: Some(target.repository.clone()),
                pull_request: Some(target.number.to_string()),
                ..PolicySubject::default()
            },
            evidence: review_target_policy_evidence(target),
        };
        enforce_reviews_policy_input(
            mutation,
            &entry.document,
            &input,
            Some(target),
            Some(entry.canvas_id.as_str()),
            ReviewsPolicyInputRequirement::None,
        )?;
    }
    Ok(())
}

pub(crate) fn enforce_review_approve_request_policy(
    request: &ReviewsApproveRequest,
) -> Result<(), CliError> {
    match request.source {
        ReviewsApproveRequestSource::Direct => {
            enforce_review_targets_policy(ReviewsGitHubMutation::Approve, &request.targets)
        }
        ReviewsApproveRequestSource::ReviewTextPaste => {
            enforce_review_text_paste_approval_policy(&request.targets)
        }
    }
}

fn enforce_review_text_paste_approval_policy(targets: &[ReviewTarget]) -> Result<(), CliError> {
    let (canvas_id, document) = enforced_review_text_paste_policy_canvas()?;
    for target in targets {
        let input = PolicyInput {
            workflow: None,
            action: ReviewsGitHubMutation::Approve.policy_action(),
            subject: PolicySubject {
                repository: Some(target.repository.clone()),
                pull_request: Some(target.number.to_string()),
                ..PolicySubject::default()
            },
            evidence: review_target_policy_evidence(target),
        };
        enforce_reviews_policy_input(
            ReviewsGitHubMutation::Approve,
            &document,
            &input,
            Some(target),
            Some(canvas_id.as_str()),
            ReviewsPolicyInputRequirement::ReviewTextPasteApproves,
        )?;
    }
    Ok(())
}

pub(crate) fn enforce_review_file_comment_policy(
    request: &ReviewsFileCommentRequest,
) -> Result<(), CliError> {
    let paths = request.path.iter().cloned().collect::<Vec<_>>();
    enforce_review_pull_request_policy(
        ReviewsGitHubMutation::FileComment,
        &request.pull_request_id,
        request.repository.as_deref(),
        &paths,
    )
}

pub(crate) fn enforce_review_pull_request_policy(
    mutation: ReviewsGitHubMutation,
    pull_request_id: &str,
    repository: Option<&str>,
    paths: &[String],
) -> Result<(), CliError> {
    let pull_request_id = pull_request_id.trim();
    let entry = enforced_reviews_github_policy_entry(mutation)?;
    let input = PolicyInput {
        workflow: None,
        action: mutation.policy_action(),
        subject: PolicySubject {
            repository: repository.map(str::to_owned),
            pull_request: (!pull_request_id.is_empty()).then(|| pull_request_id.to_owned()),
            paths: paths.to_vec(),
            ..PolicySubject::default()
        },
        evidence: PolicyEvidence::default(),
    };
    enforce_reviews_policy_input(
        mutation,
        &entry.document,
        &input,
        None,
        Some(entry.canvas_id.as_str()),
        ReviewsPolicyInputRequirement::None,
    )
}

fn enforced_review_text_paste_policy_canvas() -> Result<(String, PolicyGraph), CliError> {
    let db = DaemonDb::open(&state::daemon_root().join("harness.db"))?;
    let Some(workspace) = db.load_policy_workspace()? else {
        return Err(disabled_reviews_policy_error(
            ReviewsGitHubMutation::Approve,
            "no enforced review text paste policy canvas is live",
        ));
    };
    let Some((canvas, document)) = workspace.review_text_paste_live_canvas() else {
        return Err(disabled_reviews_policy_error(
            ReviewsGitHubMutation::Approve,
            "no enforced review text paste policy canvas is live",
        ));
    };
    Ok((canvas.id.clone(), document.clone()))
}

fn enforced_reviews_github_policy_entry(
    mutation: ReviewsGitHubMutation,
) -> Result<EnforcedReviewsPolicy, CliError> {
    let db = DaemonDb::open(&state::daemon_root().join("harness.db"))?;
    let Some(workspace) = db.load_policy_workspace()? else {
        return Err(disabled_reviews_policy_error(
            mutation,
            "no enforced policy canvas is active",
        ));
    };
    let Some((canvas, document)) = workspace
        .active_live_canvas()
        .filter(|(_canvas, document)| document.mode == PolicyGraphMode::Enforced)
    else {
        return Err(disabled_reviews_policy_error(
            mutation,
            "no enforced policy canvas is active",
        ));
    };
    Ok(EnforcedReviewsPolicy {
        canvas_id: canvas.id.clone(),
        document: document.clone(),
    })
}

fn enforce_reviews_policy_input(
    mutation: ReviewsGitHubMutation,
    document: &PolicyGraph,
    input: &PolicyInput,
    target: Option<&ReviewTarget>,
    canvas_id: Option<&str>,
    requirement: ReviewsPolicyInputRequirement,
) -> Result<(), CliError> {
    let simulation = document.simulate(input);
    if !policy_graph_covers_input(document, &simulation.visited_node_ids) {
        return Err(disabled_reviews_policy_error(
            mutation,
            "the enforced policy canvas does not cover this action",
        ));
    }
    if matches!(
        requirement,
        ReviewsPolicyInputRequirement::ReviewTextPasteApproves
    ) && !policy_path_approves_reviews(document, &simulation.visited_node_ids)
    {
        return Err(disabled_reviews_policy_error(
            mutation,
            "the enforced review text paste policy canvas does not approve pasted pull requests",
        ));
    }
    record_policy_decision(
        RecordedPolicyDecision::new(
            document.revision,
            input.clone(),
            simulation.decision.clone(),
            simulation.visited_node_ids.clone(),
            "reviews_github",
        )
        .with_canvas_id(canvas_id.map(str::to_owned)),
    );
    if simulation.decision.is_allow() {
        return Ok(());
    }
    Err(blocked_reviews_policy_error(
        mutation,
        &simulation.decision,
        target,
    ))
}

fn policy_graph_covers_input(document: &PolicyGraph, visited_node_ids: &[String]) -> bool {
    !visited_node_ids.is_empty()
        && visited_node_ids.iter().all(|node_id| {
            document
                .nodes
                .iter()
                .any(|node| node.id.as_str() == node_id.as_str())
        })
}

fn policy_path_approves_reviews(document: &PolicyGraph, visited_node_ids: &[String]) -> bool {
    visited_node_ids.iter().any(|node_id| {
        document
            .nodes
            .iter()
            .find(|node| node.id.as_str() == node_id.as_str())
            .is_some_and(|node| {
                matches!(
                    &node.kind,
                    PolicyGraphNodeKind::ActionStep(step)
                        if step.action_id == REVIEW_APPROVE_ACTION_ID
                ) || node.automation.as_ref().is_some_and(|binding| {
                    binding
                        .actions
                        .iter()
                        .any(|action| action == REVIEW_TEXT_PASTE_APPROVE_ACTION)
                })
            })
    })
}

fn disabled_reviews_policy_error(mutation: ReviewsGitHubMutation, reason: &str) -> CliError {
    CliErrorKind::invalid_transition(format!(
        "reviews GitHub {} is disabled because {reason}",
        mutation.label()
    ))
    .into()
}

fn blocked_reviews_policy_error(
    mutation: ReviewsGitHubMutation,
    decision: &PolicyDecision,
    target: Option<&ReviewTarget>,
) -> CliError {
    let target = target.map_or_else(String::new, |target| {
        format!(" for {}#{}", target.repository, target.number)
    });
    CliErrorKind::invalid_transition(format!(
        "reviews GitHub {}{target} blocked by enforced policy: {:?}",
        mutation.label(),
        decision_reason_code(decision)
    ))
    .into()
}

const fn decision_reason_code(decision: &PolicyDecision) -> PolicyReasonCode {
    match decision {
        PolicyDecision::Allow { reason_code, .. }
        | PolicyDecision::Deny { reason_code, .. }
        | PolicyDecision::RequireHuman { reason_code, .. }
        | PolicyDecision::RequireConsensus { reason_code, .. }
        | PolicyDecision::DryRunOnly { reason_code, .. } => *reason_code,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use tempfile::{TempDir, tempdir};

    use super::*;
    use crate::daemon::db::AsyncDaemonDb;
    use crate::reviews::{
        ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
        ReviewTargetFlags,
    };
    use crate::task_board::policy_graph::{PolicyActionStep, PolicyCanvasWorkspace};

    static DAEMON_ROOT_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[tokio::test]
    async fn review_text_paste_source_uses_flagged_live_canvas_for_approval() {
        let workspace = workspace_with_pasted_policy(review_text_paste_approval_graph());
        let temp = write_workspace_to_temp_daemon_root(&workspace).await;
        let _guard = DAEMON_ROOT_TEST_LOCK.lock().expect("daemon root test lock");
        let _root = state::ScopedDaemonRootOverride::set(Some(temp.path().to_path_buf()));

        let result = enforce_review_approve_request_policy(&ReviewsApproveRequest {
            targets: vec![review_target_fixture()],
            source: ReviewsApproveRequestSource::ReviewTextPaste,
        });

        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn review_text_paste_source_rejects_live_canvas_without_approval_action() {
        let workspace = workspace_with_pasted_policy(
            PolicyGraph::review_text_paste_dry_run_seeded_v2().with_mode(PolicyGraphMode::Enforced),
        );
        let temp = write_workspace_to_temp_daemon_root(&workspace).await;
        let _guard = DAEMON_ROOT_TEST_LOCK.lock().expect("daemon root test lock");
        let _root = state::ScopedDaemonRootOverride::set(Some(temp.path().to_path_buf()));

        let error = enforce_review_approve_request_policy(&ReviewsApproveRequest {
            targets: vec![review_target_fixture()],
            source: ReviewsApproveRequestSource::ReviewTextPaste,
        })
        .expect_err("dry-run pasted policy must not approve");

        assert!(
            error
                .to_string()
                .contains("does not approve pasted pull requests")
        );
    }

    #[tokio::test]
    async fn non_enforced_live_canvas_cannot_authorize_github_mutations() {
        for mode in [PolicyGraphMode::Draft, PolicyGraphMode::DryRun] {
            let mut workspace = PolicyCanvasWorkspace::seeded();
            workspace
                .active_canvas_mut()
                .expect("active policy canvas")
                .mark_live(PolicyGraph::seeded_v2().with_mode(mode));
            let temp = write_workspace_to_temp_daemon_root(&workspace).await;
            let _guard = DAEMON_ROOT_TEST_LOCK.lock().expect("daemon root test lock");
            let _root = state::ScopedDaemonRootOverride::set(Some(temp.path().to_path_buf()));

            let error = enforce_review_targets_policy(
                ReviewsGitHubMutation::Comment,
                &[review_target_fixture()],
            )
            .expect_err("non-enforced live policy must fail closed");

            assert!(
                error
                    .to_string()
                    .contains("no enforced policy canvas is active")
            );
        }
    }

    async fn write_workspace_to_temp_daemon_root(workspace: &PolicyCanvasWorkspace) -> TempDir {
        let temp = tempdir().expect("create temp daemon root");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("connect policy db");
        db.replace_policy_workspace(workspace)
            .await
            .expect("write policy workspace");
        drop(db);
        temp
    }

    fn workspace_with_pasted_policy(graph: PolicyGraph) -> PolicyCanvasWorkspace {
        let mut workspace = PolicyCanvasWorkspace::seeded();
        let canvas = workspace
            .canvases
            .iter_mut()
            .find(|canvas| canvas.is_review_text_paste_dry_run_canvas)
            .expect("pasted policy canvas");
        canvas.mark_live(graph);
        workspace
    }

    fn review_text_paste_approval_graph() -> PolicyGraph {
        let mut graph =
            PolicyGraph::review_text_paste_dry_run_seeded_v2().with_mode(PolicyGraphMode::Enforced);
        let node = graph
            .nodes
            .iter_mut()
            .find(|node| matches!(node.kind, PolicyGraphNodeKind::DryRunGate { .. }))
            .expect("dry-run gate node");
        node.label = "Approve PRs".to_owned();
        node.kind = PolicyGraphNodeKind::ActionStep(PolicyActionStep {
            action_id: REVIEW_APPROVE_ACTION_ID.to_owned(),
        });
        node.automation = None;
        graph
    }

    fn review_target_fixture() -> ReviewTarget {
        ReviewTarget {
            pull_request_id: "pr-42".to_owned(),
            repository_id: "repo-1".to_owned(),
            repository: "example/repo".to_owned(),
            number: 42,
            url: "https://github.com/example/repo/pull/42".to_owned(),
            state: ReviewPullRequestState::Open,
            head_sha: "abc123".to_owned(),
            mergeable: ReviewMergeableState::Mergeable,
            review_status: ReviewReviewStatus::ReviewRequired,
            check_status: ReviewCheckStatus::Success,
            flags: ReviewTargetFlags {
                is_draft: false,
                policy_blocked: false,
                viewer_can_update: true,
            },
            viewer_can_merge_as_admin: false,
            required_failed_check_names: Vec::new(),
            check_suite_ids: vec!["suite-1".to_owned()],
            has_conflict_markers: Some(false),
            viewer_has_active_approval: Some(false),
            auto_merge_enabled: Some(false),
            approval_requirement_satisfied_after_viewer_approval: Some(true),
        }
    }
}
