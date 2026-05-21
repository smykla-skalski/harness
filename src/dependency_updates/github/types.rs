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

#[derive(Debug, Deserialize)]
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
    #[serde(rename = "reviewDecision")]
    pub(super) review_decision: Option<String>,
    #[serde(rename = "headRefOid")]
    pub(super) head_ref_oid: Option<String>,
    pub(super) author: Option<LoginNode>,
    pub(super) repository: RepositoryNode,
    pub(super) commits: CommitConnection,
    pub(super) reviews: ReviewConnection,
    pub(super) labels: LabelConnection,
    pub(super) additions: i64,
    pub(super) deletions: i64,
    #[serde(rename = "createdAt")]
    pub(super) created_at: String,
    #[serde(rename = "updatedAt")]
    pub(super) updated_at: String,
}

#[derive(Debug, Deserialize)]
pub(super) struct LoginNode {
    pub(super) login: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct RepositoryNode {
    pub(super) id: String,
    #[serde(rename = "nameWithOwner")]
    pub(super) name_with_owner: String,
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
    pub(super) nodes: Vec<StatusContextNode>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub(super) enum StatusContextNode {
    CheckRun {
        name: String,
        status: Option<String>,
        conclusion: Option<String>,
        #[serde(rename = "checkSuite")]
        check_suite: Option<CheckSuiteNode>,
    },
    StatusContext {
        context: String,
        state: Option<String>,
    },
}

#[derive(Debug, Deserialize)]
pub(super) struct CheckSuiteNode {
    pub(super) id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ReviewConnection {
    pub(super) nodes: Vec<ReviewNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct ReviewNode {
    pub(super) author: Option<LoginNode>,
    pub(super) state: Option<String>,
}

#[derive(Debug, Deserialize)]
pub(super) struct LabelConnection {
    pub(super) nodes: Vec<LabelNode>,
}

#[derive(Debug, Deserialize)]
pub(super) struct LabelNode {
    pub(super) name: String,
}
