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
        reviewDecision
        headRefOid
        author { login }
        repository {
          id
          nameWithOwner
        }
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first: 50) {
                  nodes {
                    ... on CheckRun {
                      name
                      status
                      conclusion
                      checkSuite { id }
                    }
                    ... on StatusContext {
                      context
                      state
                    }
                  }
                }
              }
            }
          }
        }
        reviews(last: 10) {
          nodes {
            author { login }
            state
          }
        }
        labels(first: 20) {
          nodes { name }
        }
        additions
        deletions
        createdAt
        updatedAt
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
      reviewDecision
      headRefOid
      author { login }
      repository {
        id
        nameWithOwner
      }
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 50) {
                nodes {
                  ... on CheckRun {
                    name
                    status
                    conclusion
                    checkSuite { id }
                  }
                  ... on StatusContext {
                    context
                    state
                  }
                }
              }
            }
          }
        }
      }
      reviews(last: 10) {
        nodes {
          author { login }
          state
        }
      }
      labels(first: 20) {
        nodes { name }
      }
      additions
      deletions
      createdAt
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
