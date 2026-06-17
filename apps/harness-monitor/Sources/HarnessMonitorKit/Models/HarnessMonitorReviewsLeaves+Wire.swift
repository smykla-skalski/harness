import Foundation

// Maps the hand reviews leaf models (avatar / body update / file comment /
// review thread resolve) to the generated wire types in
// Models/Generated/ReviewsLeavesWireTypes.generated.swift.
//
// Requests encode (model -> wire); responses decode (wire -> model). The split
// is load-bearing where the hand model keeps an acronym casing the snake_case
// wire does not carry - avatarURL vs avatarUrl, the SHA256 fields - and where
// the body-update outcome is an open enum. The reroute of the reviews API
// client onto these wire types is a follow-up; the mapping plus the
// wire-contract test exercise the types now.

extension ReviewsAvatarRequestWire {
  init(_ model: ReviewsAvatarRequest) {
    self.init(avatarUrl: model.avatarURL)
  }
}

extension ReviewsAvatarResponse {
  init(wire: ReviewsAvatarResponseWire) {
    self.init(
      avatarURL: wire.avatarUrl,
      mimeType: wire.mimeType,
      contentBase64: wire.contentBase64,
      fetchedAt: wire.fetchedAt
    )
  }
}

extension ReviewsBodyUpdateRequestWire {
  init(_ model: ReviewsBodyUpdateRequest) {
    self.init(
      pullRequestId: model.pullRequestID,
      expectedPriorBodySha256: model.expectedPriorBodySHA256,
      newBody: model.newBody
    )
  }
}

extension ReviewsBodyUpdateResponse {
  init(wire: ReviewsBodyUpdateResponseWire) {
    self.init(
      pullRequestID: wire.pullRequestId,
      outcome: ReviewsBodyUpdateOutcome(rawValue: wire.outcome.rawValue),
      currentBody: wire.currentBody,
      currentBodySHA256: wire.currentBodySha256,
      prUpdatedAt: wire.prUpdatedAt,
      fetchedAt: wire.fetchedAt
    )
  }
}

extension ReviewsFileCommentKindWire {
  init(_ model: ReviewsFileCommentKind) {
    switch model {
    case .newThread: self = .newThread
    case .reply: self = .reply
    }
  }
}

extension ReviewsFileCommentRequestWire {
  init(_ model: ReviewsFileCommentRequest) {
    self.init(
      pullRequestId: model.pullRequestId,
      repository: model.repository,
      kind: ReviewsFileCommentKindWire(model.kind),
      body: model.body,
      path: model.path,
      line: model.line,
      side: model.side,
      threadId: model.threadId
    )
  }
}

extension ReviewsFileCommentResponse {
  init(wire: ReviewsFileCommentResponseWire) {
    self.init(
      pullRequestId: wire.pullRequestId,
      threadId: wire.threadId,
      commentId: wire.commentId,
      url: wire.url,
      fetchedAt: wire.fetchedAt
    )
  }
}

extension ReviewsReviewThreadResolveRequestWire {
  init(_ model: ReviewsReviewThreadResolveRequest) {
    self.init(threadId: model.threadId, resolved: model.resolved, pullRequestId: model.pullRequestId)
  }
}

extension ReviewsReviewThreadResolveResponse {
  init(wire: ReviewsReviewThreadResolveResponseWire) {
    self.init(threadId: wire.threadId, resolved: wire.resolved)
  }
}
