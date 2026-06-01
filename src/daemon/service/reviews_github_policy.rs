use crate::errors::{CliError, CliErrorKind};
use crate::reviews::policy::review_target_policy_evidence;
use crate::reviews::{ReviewTarget, ReviewsFileCommentRequest};
use crate::task_board::policy_graph::cached_gate_policy;
use crate::task_board::store::default_board_root;
use crate::task_board::{
    PolicyAction, PolicyDecision, PolicyGraph, PolicyGraphMode, PolicyInput, PolicyReasonCode,
    PolicySubject,
};

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
    let document = enforced_reviews_github_policy_document(mutation)?;
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
        enforce_reviews_policy_input(mutation, &document, &input, Some(target))?;
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
    let document = enforced_reviews_github_policy_document(mutation)?;
    let input = PolicyInput {
        workflow: None,
        action: mutation.policy_action(),
        subject: PolicySubject {
            repository: repository.map(str::to_owned),
            pull_request: (!pull_request_id.is_empty()).then(|| pull_request_id.to_owned()),
            paths: paths.to_vec(),
            ..PolicySubject::default()
        },
        evidence: Default::default(),
    };
    enforce_reviews_policy_input(mutation, &document, &input, None)
}

fn enforced_reviews_github_policy_document(
    mutation: ReviewsGitHubMutation,
) -> Result<PolicyGraph, CliError> {
    let root = default_board_root();
    let Some(document) = cached_gate_policy(&root) else {
        return Err(disabled_reviews_policy_error(
            mutation,
            "no enforced policy canvas is active",
        ));
    };
    if document.mode != PolicyGraphMode::Enforced {
        return Err(disabled_reviews_policy_error(
            mutation,
            "no enforced policy canvas is active",
        ));
    }
    Ok((*document).clone())
}

fn enforce_reviews_policy_input(
    mutation: ReviewsGitHubMutation,
    document: &PolicyGraph,
    input: &PolicyInput,
    target: Option<&ReviewTarget>,
) -> Result<(), CliError> {
    let simulation = document.simulate(input);
    if !policy_graph_covers_input(document, &simulation.visited_node_ids) {
        return Err(disabled_reviews_policy_error(
            mutation,
            "the enforced policy canvas does not cover this action",
        ));
    }
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
