#![allow(dead_code)]

/// Fetches one page of `pullRequest(id).timelineItems` with every nested
/// review / review-thread comment connection's first page included. The
/// service handler in A.9 follows the nested `pageInfo.hasNextPage` flags
/// via [`LIST_PR_REVIEW_COMMENTS_QUERY`] and
/// [`LIST_PR_REVIEW_THREAD_COMMENTS_QUERY`] until every connection is
/// fully drained — no partial state crosses the daemon/Monitor boundary.
pub const PR_TIMELINE_PAGE_QUERY: &str = r"
query PullRequestTimelinePage(
  $pullRequestID: ID!,
  $pageSize: Int!,
  $cursor: String,
  $inlineCommentPageSize: Int!,
  $threadCommentPageSize: Int!
) {
  node(id: $pullRequestID) {
    ... on PullRequest {
      id
      viewerCanUpdate
      timelineItems(
        first: $pageSize,
        after: $cursor,
        itemTypes: [
          ASSIGNED_EVENT,
          AUTO_MERGE_DISABLED_EVENT,
          AUTO_MERGE_ENABLED_EVENT,
          AUTO_REBASE_ENABLED_EVENT,
          AUTO_SQUASH_ENABLED_EVENT,
          BASE_REF_CHANGED_EVENT,
          BASE_REF_DELETED_EVENT,
          BASE_REF_FORCE_PUSHED_EVENT,
          CLOSED_EVENT,
          CONNECTED_EVENT,
          CONVERT_TO_DRAFT_EVENT,
          CROSS_REFERENCED_EVENT,
          DEMILESTONED_EVENT,
          DISCONNECTED_EVENT,
          HEAD_REF_DELETED_EVENT,
          HEAD_REF_FORCE_PUSHED_EVENT,
          HEAD_REF_RESTORED_EVENT,
          ISSUE_COMMENT,
          LABELED_EVENT,
          LOCKED_EVENT,
          MARKED_AS_DUPLICATE_EVENT,
          MENTIONED_EVENT,
          MERGED_EVENT,
          MILESTONED_EVENT,
          PINNED_EVENT,
          PULL_REQUEST_COMMIT,
          PULL_REQUEST_REVIEW,
          PULL_REQUEST_REVIEW_THREAD,
          PULL_REQUEST_REVISION_MARKER,
          READY_FOR_REVIEW_EVENT,
          REFERENCED_EVENT,
          RENAMED_TITLE_EVENT,
          REOPENED_EVENT,
          REVIEW_DISMISSED_EVENT,
          REVIEW_REQUESTED_EVENT,
          REVIEW_REQUEST_REMOVED_EVENT,
          SUBSCRIBED_EVENT,
          TRANSFERRED_EVENT,
          UNASSIGNED_EVENT,
          UNLABELED_EVENT,
          UNLOCKED_EVENT,
          UNMARKED_AS_DUPLICATE_EVENT,
          UNPINNED_EVENT,
          UNSUBSCRIBED_EVENT
        ]
      ) {
        pageInfo { startCursor endCursor hasNextPage hasPreviousPage }
        nodes {
          __typename
          ...IssueCommentFields
          ...PullRequestReviewFields
          ...PullRequestReviewThreadFields
          ...PullRequestCommitFields
          ...HeadRefForcePushedFields
          ...LabeledFields
          ...UnlabeledFields
          ...AssignedFields
          ...UnassignedFields
          ...MilestonedFields
          ...DemilestonedFields
          ...RenamedTitleFields
          ...ReviewRequestedFields
          ...ReviewRequestRemovedFields
          ...ReviewDismissedFields
          ...LockedFields
          ...UnlockedFields
          ...ReferencedFields
          ...CrossReferencedFields
          ...ConnectedFields
          ...DisconnectedFields
          ...BaseRefChangedFields
          ...BaseRefForcePushedFields
          ...BaseRefDeletedFields
          ...HeadRefDeletedFields
          ...HeadRefRestoredFields
          ...MergedFields
          ...ClosedFields
          ...ReopenedFields
          ...ReadyForReviewFields
          ...ConvertToDraftFields
          ...AutoMergeEnabledFields
          ...AutoMergeDisabledFields
          ...AutoRebaseEnabledFields
          ...AutoSquashEnabledFields
          ...PinnedFields
          ...UnpinnedFields
          ...MentionedFields
          ...SubscribedFields
          ...UnsubscribedFields
          ...MarkedAsDuplicateFields
          ...UnmarkedAsDuplicateFields
          ...TransferredFields
          ...RevisionMarkerFields
        }
      }
    }
  }
  rateLimit { remaining resetAt cost }
}

fragment ActorBrief on Actor {
  login
  avatarUrl
}

fragment ReferenceableSubject on ReferencedSubject {
  __typename
  ... on Issue { number title url repository { nameWithOwner } }
  ... on PullRequest { number title url repository { nameWithOwner } }
}

fragment RequestedReviewerBrief on RequestedReviewer {
  __typename
  ... on User { login }
  ... on Team { slug name }
  ... on Bot { login }
  ... on Mannequin { login }
}

fragment AssigneeBrief on Assignee {
  __typename
  ... on User { login }
  ... on Bot { login }
  ... on Mannequin { login }
}

fragment IssueCommentFields on IssueComment {
  id
  createdAt
  updatedAt
  body
  bodyText
  isMinimized
  minimizedReason
  reactions { totalCount }
  viewerDidAuthor
  viewerCanUpdate
  url
  author { ...ActorBrief }
}

fragment PullRequestReviewFields on PullRequestReview {
  id
  createdAt
  state
  body
  url
  author { ...ActorBrief }
  comments(first: $inlineCommentPageSize) {
    pageInfo { endCursor hasNextPage }
    nodes {
      id
      path
      position
      line
      originalLine
      diffHunk
      outdated
      body
      createdAt
      url
      replyTo { id }
      author { ...ActorBrief }
    }
  }
}

fragment PullRequestReviewThreadFields on PullRequestReviewThread {
  id
  isResolved
  isCollapsed
  isOutdated
  path
  line
  originalLine
  diffSide
  comments(first: $threadCommentPageSize) {
    pageInfo { endCursor hasNextPage }
    nodes {
      id
      diffHunk
      body
      createdAt
      url
      author { ...ActorBrief }
    }
  }
}

fragment PullRequestCommitFields on PullRequestCommit {
  id
  url
  commit {
    oid
    abbreviatedOid
    messageHeadline
    committedDate
    author { name user { login avatarUrl } }
  }
}

fragment HeadRefForcePushedFields on HeadRefForcePushedEvent {
  id
  createdAt
  actor { ...ActorBrief }
  beforeCommit { oid abbreviatedOid }
  afterCommit { oid abbreviatedOid }
  ref { name }
}

fragment LabeledFields on LabeledEvent {
  id createdAt actor { ...ActorBrief } label { name color }
}

fragment UnlabeledFields on UnlabeledEvent {
  id createdAt actor { ...ActorBrief } label { name color }
}

fragment AssignedFields on AssignedEvent {
  id createdAt actor { ...ActorBrief }
  assignee { ...AssigneeBrief }
}

fragment UnassignedFields on UnassignedEvent {
  id createdAt actor { ...ActorBrief }
  assignee { ...AssigneeBrief }
}

fragment MilestonedFields on MilestonedEvent {
  id createdAt actor { ...ActorBrief } milestoneTitle
}

fragment DemilestonedFields on DemilestonedEvent {
  id createdAt actor { ...ActorBrief } milestoneTitle
}

fragment RenamedTitleFields on RenamedTitleEvent {
  id createdAt actor { ...ActorBrief } previousTitle currentTitle
}

fragment ReviewRequestedFields on ReviewRequestedEvent {
  id createdAt actor { ...ActorBrief }
  requestedReviewer { ...RequestedReviewerBrief }
}

fragment ReviewRequestRemovedFields on ReviewRequestRemovedEvent {
  id createdAt actor { ...ActorBrief }
  requestedReviewer { ...RequestedReviewerBrief }
}

fragment ReviewDismissedFields on ReviewDismissedEvent {
  id createdAt actor { ...ActorBrief } dismissalMessage
}

fragment LockedFields on LockedEvent {
  id createdAt actor { ...ActorBrief } lockReason
}

fragment UnlockedFields on UnlockedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment ReferencedFields on ReferencedEvent {
  id createdAt actor { ...ActorBrief }
  commit { oid abbreviatedOid }
  subject { ...ReferenceableSubject }
}

fragment CrossReferencedFields on CrossReferencedEvent {
  id createdAt actor { ...ActorBrief }
  source { ...ReferenceableSubject }
}

fragment ConnectedFields on ConnectedEvent {
  id createdAt actor { ...ActorBrief }
  subject { ...ReferenceableSubject }
}

fragment DisconnectedFields on DisconnectedEvent {
  id createdAt actor { ...ActorBrief }
  subject { ...ReferenceableSubject }
}

fragment BaseRefChangedFields on BaseRefChangedEvent {
  id createdAt actor { ...ActorBrief } previousRefName currentRefName
}

fragment BaseRefForcePushedFields on BaseRefForcePushedEvent {
  id createdAt actor { ...ActorBrief }
  beforeCommit { oid abbreviatedOid }
  afterCommit { oid abbreviatedOid }
  ref { name }
}

fragment BaseRefDeletedFields on BaseRefDeletedEvent {
  id createdAt actor { ...ActorBrief } baseRefName
}

fragment HeadRefDeletedFields on HeadRefDeletedEvent {
  id createdAt actor { ...ActorBrief } headRefName
}

fragment HeadRefRestoredFields on HeadRefRestoredEvent {
  id createdAt actor { ...ActorBrief }
}

fragment MergedFields on MergedEvent {
  id createdAt actor { ...ActorBrief }
  commit { oid abbreviatedOid }
  mergeRefName
}

fragment ClosedFields on ClosedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment ReopenedFields on ReopenedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment ReadyForReviewFields on ReadyForReviewEvent {
  id createdAt actor { ...ActorBrief }
}

fragment ConvertToDraftFields on ConvertToDraftEvent {
  id createdAt actor { ...ActorBrief }
}

fragment AutoMergeEnabledFields on AutoMergeEnabledEvent {
  id createdAt actor { ...ActorBrief }
}

fragment AutoMergeDisabledFields on AutoMergeDisabledEvent {
  id createdAt actor { ...ActorBrief }
}

fragment AutoRebaseEnabledFields on AutoRebaseEnabledEvent {
  id createdAt actor { ...ActorBrief }
}

fragment AutoSquashEnabledFields on AutoSquashEnabledEvent {
  id createdAt actor { ...ActorBrief }
}

fragment PinnedFields on PinnedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment UnpinnedFields on UnpinnedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment MentionedFields on MentionedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment SubscribedFields on SubscribedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment UnsubscribedFields on UnsubscribedEvent {
  id createdAt actor { ...ActorBrief }
}

fragment MarkedAsDuplicateFields on MarkedAsDuplicateEvent {
  id createdAt actor { ...ActorBrief }
}

fragment UnmarkedAsDuplicateFields on UnmarkedAsDuplicateEvent {
  id createdAt actor { ...ActorBrief }
}

fragment TransferredFields on TransferredEvent {
  id createdAt actor { ...ActorBrief }
  fromRepository { nameWithOwner }
}

fragment RevisionMarkerFields on PullRequestRevisionMarker {
  createdAt
  lastSeenCommit { oid abbreviatedOid }
}
";

/// Continuation query: fetch the next page of inline comments for a
/// single `PullRequestReview` node identified by `$reviewID`. The
/// service handler invokes this whenever the embedded first page of
/// `PullRequestReviewFields.comments` reports `hasNextPage: true`, and
/// keeps invoking it until the connection is exhausted (subject to the
/// drain budget defined in the plan §2.6).
pub const LIST_PR_REVIEW_COMMENTS_QUERY: &str = r"
query ListPRReviewComments($reviewID: ID!, $pageSize: Int!, $cursor: String) {
  node(id: $reviewID) {
    ... on PullRequestReview {
      comments(first: $pageSize, after: $cursor) {
        pageInfo { endCursor hasNextPage }
        nodes {
          id
          path
          position
          line
          originalLine
          diffHunk
          outdated
          body
          createdAt
          url
          replyTo { id }
          author { login avatarUrl }
        }
      }
    }
  }
  rateLimit { remaining resetAt cost }
}
";

/// Continuation query: fetch the next page of comments for a single
/// `PullRequestReviewThread` node identified by `$threadID`. Used in
/// the same drain loop as [`LIST_PR_REVIEW_COMMENTS_QUERY`].
pub const LIST_PR_REVIEW_THREAD_COMMENTS_QUERY: &str = r"
query ListPRReviewThreadComments($threadID: ID!, $pageSize: Int!, $cursor: String) {
  node(id: $threadID) {
    ... on PullRequestReviewThread {
      comments(first: $pageSize, after: $cursor) {
        pageInfo { endCursor hasNextPage }
        nodes {
          id
          diffHunk
          body
          createdAt
          url
          author { login avatarUrl }
        }
      }
    }
  }
  rateLimit { remaining resetAt cost }
}
";
