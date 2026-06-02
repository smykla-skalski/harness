use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub(super) struct SearchResponse {
    pub(super) search: SearchConnection,
}

#[derive(Debug, Deserialize)]
pub(super) struct SearchConnection {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: PageInfo,
    pub(super) nodes: Vec<SearchNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct NodesResponse {
    pub(super) nodes: Vec<Option<SearchNode>>,
}

#[derive(Debug, Deserialize)]
pub(super) struct OrganizationRepositoriesResponse {
    pub(super) organization: Option<OrganizationRepositoriesNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct OrganizationRepositoriesNode {
    pub(super) repositories: OrganizationRepositoriesConnection,
}

#[derive(Debug, Deserialize)]
pub(super) struct OrganizationRepositoriesConnection {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: PageInfo,
    pub(super) nodes: Vec<OrganizationRepositoryNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct OrganizationRepositoryNode {
    #[serde(rename = "nameWithOwner")]
    pub(super) name_with_owner: String,
}

#[derive(Debug, Deserialize, Clone)]
pub(super) struct PageInfo {
    #[serde(rename = "hasNextPage")]
    pub(super) has_next_page: bool,
    #[serde(rename = "endCursor")]
    pub(super) end_cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct SearchNode {
    pub(super) id: String,
    pub(super) number: u64,
    pub(super) title: String,
    pub(super) url: String,
    pub(super) state: Option<String>,
    pub(super) mergeable: Option<String>,
    #[serde(rename = "isDraft")]
    pub(super) is_draft: bool,
    #[serde(rename = "viewerCanMergeAsAdmin", default)]
    pub(super) viewer_can_merge_as_admin: Option<bool>,
    #[serde(rename = "reviewDecision")]
    pub(super) review_decision: Option<String>,
    #[serde(rename = "headRefOid")]
    pub(super) head_ref_oid: Option<String>,
    pub(super) author: Option<LoginNode>,
    #[serde(rename = "authorAssociation", default)]
    pub(super) author_association: Option<String>,
    #[serde(rename = "reviewRequests", default)]
    pub(super) review_requests: Option<ReviewRequestConnection>,
    pub(super) repository: RepositoryNode,
    pub(super) commits: CommitConnection,
    #[serde(rename = "baseRef", default)]
    pub(super) base_ref: Option<RefNode>,
    pub(super) reviews: ReviewConnection,
    pub(super) labels: LabelConnection,
    pub(super) additions: i64,
    pub(super) deletions: i64,
    #[serde(rename = "createdAt")]
    pub(super) created_at: String,
    #[serde(rename = "updatedAt")]
    pub(super) updated_at: String,
    #[serde(rename = "viewerCanUpdate", default)]
    pub(super) viewer_can_update: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub(super) struct LoginNode {
    pub(super) login: Option<String>,
    #[serde(rename = "avatarUrl", default)]
    pub(super) avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct RepositoryNode {
    pub(super) id: String,
    #[serde(rename = "nameWithOwner")]
    pub(super) name_with_owner: String,
    #[serde(default)]
    pub(super) labels: Option<RepositoryLabelConnection>,
}

#[derive(Debug, Deserialize)]
pub(super) struct RefNode {
    #[serde(rename = "branchProtectionRule", default)]
    pub(super) branch_protection_rule: Option<BranchProtectionRuleNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct BranchProtectionRuleNode {
    #[serde(rename = "requiredStatusCheckContexts", default)]
    pub(super) required_status_check_contexts: Vec<String>,
    #[serde(rename = "requiredStatusChecks", default)]
    pub(super) required_status_checks: Vec<RequiredStatusCheckNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct RequiredStatusCheckNode {
    pub(super) context: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct RepositoryLabelConnection {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: PageInfo,
    pub(super) nodes: Vec<RepositoryLabelNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct RepositoryLabelNode {
    pub(super) name: String,
    #[serde(default)]
    pub(super) color: Option<String>,
    #[serde(default)]
    pub(super) description: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct CommitConnection {
    pub(super) nodes: Vec<CommitNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct CommitNode {
    pub(super) commit: Option<CommitPayload>,
}

#[derive(Debug, Deserialize)]
pub(super) struct CommitPayload {
    #[serde(rename = "statusCheckRollup")]
    pub(super) status_check_rollup: Option<StatusCheckRollup>,
}

#[derive(Debug, Deserialize)]
pub(super) struct StatusCheckRollup {
    pub(super) contexts: StatusCheckContexts,
}

#[derive(Debug, Deserialize)]
pub(super) struct StatusCheckContexts {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: PageInfo,
    pub(super) nodes: Vec<StatusContextNode>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum StatusContextNode {
    CheckRun {
        name: String,
        status: Option<String>,
        conclusion: Option<String>,
        url: Option<String>,
        #[serde(rename = "checkSuite")]
        check_suite: Option<CheckSuiteNode>,
    },
    StatusContext {
        context: String,
        state: Option<String>,
        #[serde(rename = "targetUrl")]
        target_url: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
pub(super) struct CheckSuiteNode {
    pub(super) id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ReviewConnection {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: PageInfo,
    pub(super) nodes: Vec<ReviewNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ReviewRequestConnection {
    pub(super) nodes: Vec<ReviewRequestNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ReviewRequestNode {
    #[serde(rename = "requestedReviewer")]
    pub(super) requested_reviewer: Option<RequestedReviewerNode>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum RequestedReviewerNode {
    User {
        login: Option<String>,
    },
    Bot {
        login: Option<String>,
    },
    Mannequin {
        login: Option<String>,
    },
    Team {
        #[serde(rename = "slug")]
        _slug: Option<String>,
        #[serde(rename = "name")]
        _name: Option<String>,
    },
}

impl RequestedReviewerNode {
    pub(super) fn login(&self) -> Option<&str> {
        match self {
            Self::User { login } | Self::Bot { login } | Self::Mannequin { login } => {
                login.as_deref()
            }
            Self::Team { .. } => None,
        }
    }
}

#[derive(Debug, Deserialize)]
pub(super) struct ReviewNode {
    pub(super) author: Option<LoginNode>,
    pub(super) state: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct LabelConnection {
    #[serde(rename = "pageInfo")]
    pub(super) page_info: PageInfo,
    pub(super) nodes: Vec<LabelNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct LabelNode {
    pub(super) name: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestLabelsPageResponse {
    pub(super) node: Option<PullRequestLabelsPageNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestLabelsPageNode {
    pub(super) labels: LabelConnection,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestReviewsPageResponse {
    pub(super) node: Option<PullRequestReviewsPageNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestReviewsPageNode {
    pub(super) reviews: ReviewConnection,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestChecksPageResponse {
    pub(super) node: Option<PullRequestChecksPageNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestChecksPageNode {
    pub(super) commits: CommitConnection,
}

#[derive(Debug, Deserialize)]
pub(super) struct RepositoryLabelsPageResponse {
    pub(super) node: Option<RepositoryLabelsPageNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct RepositoryLabelsPageNode {
    #[serde(rename = "nameWithOwner")]
    pub(super) name_with_owner: String,
    pub(super) labels: RepositoryLabelConnection,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestBodyResponse {
    pub(super) node: Option<PullRequestBodyNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct PullRequestBodyNode {
    #[serde(default)]
    pub(super) body: Option<String>,
    #[serde(rename = "updatedAt")]
    pub(super) updated_at: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct UpdatePullRequestBodyResponse {
    #[serde(rename = "updatePullRequest")]
    pub(super) update_pull_request: Option<UpdatePullRequestBodyPayload>,
}

#[derive(Debug, Deserialize)]
pub(super) struct UpdatePullRequestBodyPayload {
    #[serde(rename = "pullRequest")]
    pub(super) pull_request: Option<PullRequestBodyNode>,
}
