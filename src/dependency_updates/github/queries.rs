pub(super) const SEARCH_QUERY: &str = r"
query SearchDependencyUpdates($query: String!, $after: String) {
  search(query: $query, type: ISSUE, first: 100, after: $after) {
    pageInfo {
      hasNextPage
      endCursor
    }
    nodes {
      ... on PullRequest {
        id
        number
        title
        url
        state
        mergeable
        isDraft
        viewerCanMergeAsAdmin
        reviewDecision
        headRefOid
        author { login }
        repository {
          id
          nameWithOwner
          labels(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes {
              name
              color
              description
            }
          }
        }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first: 100) {
                  pageInfo { hasNextPage endCursor }
                  nodes {
                    ... on CheckRun {
                      name
                      status
                      conclusion
                      url
                      checkSuite { id }
                    }
                    ... on StatusContext {
                      context
                      state
                      targetUrl
                    }
                  }
                }
              }
            }
          }
        }
        baseRef {
          branchProtectionRule {
            requiredStatusCheckContexts
            requiredStatusChecks { context }
          }
        }
        reviews(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            author { login }
            state
          }
        }
        labels(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { name }
        }
        additions
        deletions
        createdAt
        updatedAt
        viewerCanUpdate
      }
    }
  }
}
";

pub(super) const ORGANIZATION_REPOSITORIES_QUERY: &str = r"
query OrganizationRepositories($organization: String!, $after: String) {
  organization(login: $organization) {
    repositories(first: 100, after: $after, orderBy: { field: NAME, direction: ASC }) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        nameWithOwner
      }
    }
  }
}
";

pub(super) const NODES_BY_IDS_QUERY: &str = r"
query DependencyUpdateNodes($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on PullRequest {
      id
      number
      title
      url
      state
      mergeable
      isDraft
      viewerCanMergeAsAdmin
      reviewDecision
      headRefOid
      author { login }
      repository {
        id
        nameWithOwner
        labels(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            name
            color
            description
          }
        }
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 100) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    url
                    checkSuite { id }
                  }
                  ... on StatusContext {
                    context
                    state
                    targetUrl
                  }
                }
              }
            }
          }
        }
      }
      baseRef {
        branchProtectionRule {
          requiredStatusCheckContexts
          requiredStatusChecks { context }
        }
      }
      reviews(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          author { login }
          state
        }
      }
      labels(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
      additions
      deletions
      createdAt
      updatedAt
      viewerCanUpdate
    }
  }
}
";

pub(super) const PR_LABELS_PAGE_QUERY: &str = r"
query DependencyUpdatePullRequestLabelsPage($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      labels(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
    }
  }
}
";

pub(super) const PR_REVIEWS_PAGE_QUERY: &str = r"
query DependencyUpdatePullRequestReviewsPage($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      reviews(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          author { login }
          state
        }
      }
    }
  }
}
";

pub(super) const PR_CHECKS_PAGE_QUERY: &str = r"
query DependencyUpdatePullRequestChecksPage($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    url
                    checkSuite { id }
                  }
                  ... on StatusContext {
                    context
                    state
                    targetUrl
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
";

pub(super) const REPO_LABELS_PAGE_QUERY: &str = r"
query DependencyUpdateRepositoryLabelsPage($id: ID!, $after: String) {
  node(id: $id) {
    ... on Repository {
      nameWithOwner
      labels(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          name
          color
          description
        }
      }
    }
  }
}
";

pub(super) const PULL_REQUEST_BODY_QUERY: &str = r"
query PullRequestBody($id: ID!) {
  node(id: $id) {
    ... on PullRequest {
      body
      updatedAt
    }
  }
}
";

pub(super) const APPROVE_MUTATION: &str = r"
mutation ApproveDependencyUpdate($id: ID!) {
  addPullRequestReview(input: { pullRequestId: $id, event: APPROVE }) {
    pullRequestReview { state }
  }
}
";

pub(super) const REREQUEST_CHECK_SUITE_MUTATION: &str = r"
mutation RerequestDependencyUpdateCheckSuite($checkSuiteId: ID!, $repositoryId: ID!) {
  rerequestCheckSuite(input: { checkSuiteId: $checkSuiteId, repositoryId: $repositoryId }) {
    checkSuite { id }
  }
}
";

pub(super) const UPDATE_PULL_REQUEST_BODY_MUTATION: &str = r"
mutation UpdateDependencyUpdatePullRequestBody($id: ID!, $body: String!) {
  updatePullRequest(input: { pullRequestId: $id, body: $body }) {
    pullRequest {
      body
      updatedAt
    }
  }
}
";

pub(super) const ADD_COMMENT_MUTATION: &str = r"
mutation AddDependencyUpdateComment($id: ID!, $body: String!) {
  addComment(input: { subjectId: $id, body: $body }) {
    commentEdge {
      node {
        id
      }
    }
  }
}
";

pub(crate) const LIST_PR_FILES_QUERY: &str = r"
query ListDependencyUpdatePullRequestFiles($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      headRefOid
      headRefName
      baseRefOid
      baseRefName
      viewerCanUpdate
      repository {
        nameWithOwner
      }
      files(first: 100, after: $after) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          path
          additions
          deletions
          changeType
          viewerViewedState
        }
      }
    }
  }
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
}
";

#[allow(dead_code)] // wired into service handler in A.10
pub(crate) const MARK_PR_FILE_AS_VIEWED_MUTATION: &str = r"
mutation MarkDependencyUpdatePullRequestFileAsViewed($pullRequestId: ID!, $path: String!) {
  markFileAsViewed(input: { pullRequestId: $pullRequestId, path: $path }) {
    pullRequest {
      id
    }
  }
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
}
";

#[allow(dead_code)] // wired into service handler in A.10
pub(crate) const UNMARK_PR_FILE_AS_VIEWED_MUTATION: &str = r"
mutation UnmarkDependencyUpdatePullRequestFileAsViewed($pullRequestId: ID!, $path: String!) {
  unmarkFileAsViewed(input: { pullRequestId: $pullRequestId, path: $path }) {
    pullRequest {
      id
    }
  }
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
}
";

#[allow(dead_code)] // wired into service handler in A.10
pub(crate) const REPOSITORY_BLOB_QUERY: &str = r"
query DependencyUpdateRepositoryBlob($id: ID!, $expression: String!) {
  node(id: $id) {
    ... on Repository {
      object(expression: $expression) {
        ... on Blob {
          oid
          byteSize
          isBinary
          isTruncated
          text
        }
      }
    }
  }
  rateLimit {
    limit
    cost
    remaining
    resetAt
  }
}
";
