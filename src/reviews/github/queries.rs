pub(super) const SEARCH_QUERY: &str = r"
query SearchReviews($query: String!, $after: String) {
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
        baseRefName
        author { login avatarUrl }
        authorAssociation
        reviewRequests(first: 100) {
          nodes {
            requestedReviewer {
              ... on User { login }
              ... on Bot { login }
              ... on Mannequin { login }
              ... on Team { slug name }
            }
          }
        }
        repository {
          id
          nameWithOwner
          defaultBranchRef { name }
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
            author { login avatarUrl }
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
query ReviewNodes($ids: [ID!]!) {
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
      baseRefName
      author { login avatarUrl }
      authorAssociation
      reviewRequests(first: 100) {
        nodes {
          requestedReviewer {
            ... on User { login }
            ... on Bot { login }
            ... on Mannequin { login }
            ... on Team { slug name }
          }
        }
      }
      repository {
        id
        nameWithOwner
        defaultBranchRef { name }
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
          author { login avatarUrl }
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
query ReviewPullRequestLabelsPage($id: ID!, $after: String) {
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
query ReviewPullRequestReviewsPage($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      reviews(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          author { login avatarUrl }
          state
        }
      }
    }
  }
}
";

pub(super) const PR_CHECKS_PAGE_QUERY: &str = r"
query ReviewPullRequestChecksPage($id: ID!, $after: String) {
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
query ReviewRepositoryLabelsPage($id: ID!, $after: String) {
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

pub(super) const VIEWER_LOGIN_QUERY: &str = r"
query ReviewsViewerLogin {
  viewer {
    login
  }
}
";

pub(super) const APPROVE_MUTATION: &str = r"
mutation ApproveReview($id: ID!) {
  addPullRequestReview(input: { pullRequestId: $id, event: APPROVE }) {
    pullRequestReview { state }
  }
}
";

pub(super) const REREQUEST_CHECK_SUITE_MUTATION: &str = r"
mutation RerequestReviewCheckSuite($checkSuiteId: ID!, $repositoryId: ID!) {
  rerequestCheckSuite(input: { checkSuiteId: $checkSuiteId, repositoryId: $repositoryId }) {
    checkSuite { id }
  }
}
";

pub(super) const UPDATE_PULL_REQUEST_BODY_MUTATION: &str = r"
mutation UpdateReviewPullRequestBody($id: ID!, $body: String!) {
  updatePullRequest(input: { pullRequestId: $id, body: $body }) {
    pullRequest {
      body
      updatedAt
    }
  }
}
";

pub(super) const ADD_COMMENT_MUTATION: &str = r"
mutation AddReviewComment($id: ID!, $body: String!) {
  addComment(input: { subjectId: $id, body: $body }) {
    commentEdge {
      node {
        __typename
        id
        author { login avatarUrl }
        body
        bodyText
        createdAt
        updatedAt
        isMinimized
        minimizedReason
        reactions { totalCount }
        viewerDidAuthor
        viewerCanUpdate
        url
      }
    }
  }
}
";

/// Resolve a `PullRequestReviewThread` by its node ID. Returns the
/// updated thread's `isResolved` flag so the daemon can echo the
/// confirmed server-side state.
pub(crate) const RESOLVE_REVIEW_THREAD_MUTATION: &str = r"
mutation ResolveReviewReviewThread($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
";

/// Inverse of `RESOLVE_REVIEW_THREAD_MUTATION` — unresolves a
/// previously-resolved review thread.
pub(crate) const UNRESOLVE_REVIEW_THREAD_MUTATION: &str = r"
mutation UnresolveReviewReviewThread($threadId: ID!) {
  unresolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}
";

pub(super) const ADD_REVIEW_THREAD_MUTATION: &str = r"
mutation AddReviewFileThread(
  $pullRequestId: ID!,
  $body: String!,
  $path: String!,
  $line: Int!,
  $side: DiffSide!
) {
  addPullRequestReviewThread(input: {
    pullRequestId: $pullRequestId,
    body: $body,
    path: $path,
    line: $line,
    side: $side
  }) {
    thread {
      id
      comments(first: 1) {
        nodes { id url }
      }
    }
  }
}
";

pub(super) const ADD_REVIEW_THREAD_REPLY_MUTATION: &str = r"
mutation AddReviewFileThreadReply($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: $threadId,
    body: $body
  }) {
    comment { id url }
  }
}
";

pub(crate) const LIST_PR_FILES_QUERY: &str = r"
query ListReviewPullRequestFiles($id: ID!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      number
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

pub(crate) const MARK_PR_FILE_AS_VIEWED_MUTATION: &str = r"
mutation MarkReviewPullRequestFileAsViewed($pullRequestId: ID!, $path: String!) {
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

pub(crate) const UNMARK_PR_FILE_AS_VIEWED_MUTATION: &str = r"
mutation UnmarkReviewPullRequestFileAsViewed($pullRequestId: ID!, $path: String!) {
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

pub(crate) const REPOSITORY_BLOB_QUERY: &str = r"
query ReviewRepositoryBlob($id: ID!, $expression: String!) {
  node(id: $id) {
    ... on Repository {
      nameWithOwner
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
