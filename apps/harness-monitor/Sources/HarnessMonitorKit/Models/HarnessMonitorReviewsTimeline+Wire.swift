import Foundation

// Maps the hand reviews timeline models to the generated wire types in
// Models/Generated/ReviewsTimelineWireTypes.generated.swift. The wire types own
// the daemon snake_case shape with explicit CodingKeys, so the timeline decode
// runs through them on the plain PolicyWireCoding decoder instead of riding the
// transport's convertFromSnakeCase. The hand payloads diverge from the wire in
// three spots the mapping bridges: ReviewTimelineActor.avatarURL is a URL parsed
// from the wire String, the state / eventKind enums share rawValues with their
// wire twins, and UnknownTimelinePayload.rawPayload is the app's
// AnyCodableJSONValue mirror of the wire JSONValue (a wire .null maps to nil so
// an absent raw_payload stays absent, matching the prior decodeIfPresent).

extension ReviewTimelineActor {
  init(wire: ActorWire) {
    self.init(login: wire.login, avatarURL: wire.avatarUrl.flatMap { URL(string: $0) })
  }
}

extension AnyCodableJSONValue {
  init(jsonValue: JSONValue) {
    switch jsonValue {
    case .null:
      self = .null
    case .bool(let value):
      self = .bool(value)
    case .number(let value):
      self = .number(value)
    case .string(let value):
      self = .string(value)
    case .array(let items):
      self = .array(items.map(Self.init(jsonValue:)))
    case .object(let fields):
      self = .object(fields.mapValues(Self.init(jsonValue:)))
    }
  }
}

extension IssueCommentPayload {
  init(wire: IssueCommentEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      body: wire.body,
      bodyText: wire.bodyText,
      isMinimized: wire.isMinimized,
      minimizedReason: wire.minimizedReason,
      reactionsTotal: wire.reactionsTotal,
      viewerDidAuthor: wire.viewerDidAuthor,
      viewerCanEdit: wire.viewerCanEdit,
      url: wire.url
    )
  }
}

extension ReviewInlineCommentPayload {
  init(wire: ReviewInlineCommentEntryWire) {
    self.init(
      id: wire.id,
      path: wire.path,
      position: wire.position,
      line: wire.line,
      originalLine: wire.originalLine,
      diffHunk: wire.diffHunk,
      body: wire.body,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      replyToId: wire.replyToId,
      outdated: wire.outdated,
      url: wire.url
    )
  }
}

extension ReviewPayload {
  init(wire: ReviewEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      state: ReviewReviewState(rawValue: wire.state.rawValue) ?? .commented,
      body: wire.body,
      url: wire.url,
      inlineComments: wire.inlineComments.map(ReviewInlineCommentPayload.init(wire:)),
      commentsTruncated: wire.commentsTruncated
    )
  }
}

extension ReviewThreadCommentPayload {
  init(wire: ReviewThreadCommentEntryWire) {
    self.init(
      id: wire.id,
      body: wire.body,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      url: wire.url
    )
  }
}

extension ReviewThreadPayload {
  init(wire: ReviewThreadEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      isResolved: wire.isResolved,
      isCollapsed: wire.isCollapsed,
      path: wire.path,
      line: wire.line,
      originalLine: wire.originalLine,
      diffSide: wire.diffSide,
      diffHunk: wire.diffHunk,
      outdated: wire.outdated,
      comments: wire.comments.map(ReviewThreadCommentPayload.init(wire:)),
      commentsTruncated: wire.commentsTruncated
    )
  }
}

extension CommitPayload {
  init(wire: CommitEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      oid: wire.oid,
      abbreviatedOid: wire.abbreviatedOid,
      messageHeadline: wire.messageHeadline,
      committedDate: wire.committedDate,
      authorName: wire.authorName,
      authorLogin: wire.authorLogin,
      url: wire.url
    )
  }
}

extension HeadRefForcePushedPayload {
  init(wire: HeadRefForcePushedEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      beforeOid: wire.beforeOid,
      beforeAbbreviatedOid: wire.beforeAbbreviatedOid,
      afterOid: wire.afterOid,
      afterAbbreviatedOid: wire.afterAbbreviatedOid,
      refName: wire.refName
    )
  }
}

extension SimpleActorEventPayload {
  init(wire: SimpleActorEventEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      eventKind: SimpleActorEventKind(rawValue: wire.eventKind.rawValue) ?? .referenced,
      label: wire.label,
      labelColor: wire.labelColor,
      milestoneTitle: wire.milestoneTitle,
      oldTitle: wire.oldTitle,
      newTitle: wire.newTitle,
      sourceURL: wire.sourceUrl,
      sourceTitle: wire.sourceTitle,
      sourceNumber: wire.sourceNumber,
      branchName: wire.branchName,
      beforeOid: wire.beforeOid,
      afterOid: wire.afterOid,
      lockReason: wire.lockReason,
      dismissalMessage: wire.dismissalMessage,
      requestedReviewerLogin: wire.requestedReviewerLogin,
      requestedReviewerTeamSlug: wire.requestedReviewerTeamSlug,
      assigneeLogin: wire.assigneeLogin,
      sourceRepository: wire.sourceRepository,
      destinationRepository: wire.destinationRepository
    )
  }
}

extension UnknownTimelinePayload {
  init(wire: UnknownEntryWire) {
    self.init(
      id: wire.id,
      createdAt: wire.createdAt,
      actor: wire.actor.map(ReviewTimelineActor.init(wire:)),
      typename: wire.typename,
      rawPayload: wire.rawPayload == .null
        ? nil
        : AnyCodableJSONValue(jsonValue: wire.rawPayload)
    )
  }
}

extension ReviewTimelineEntry {
  init(wire: ReviewTimelineEntryWire) {
    switch wire {
    case .issueComment(let value):
      self = .issueComment(IssueCommentPayload(wire: value))
    case .review(let value):
      self = .review(ReviewPayload(wire: value))
    case .reviewThread(let value):
      self = .reviewThread(ReviewThreadPayload(wire: value))
    case .commit(let value):
      self = .commit(CommitPayload(wire: value))
    case .headRefForcePushed(let value):
      self = .headRefForcePushed(HeadRefForcePushedPayload(wire: value))
    case .simpleActorEvent(let value):
      self = .simpleActorEvent(SimpleActorEventPayload(wire: value))
    case .unknown(let value):
      self = .unknown(UnknownTimelinePayload(wire: value))
    }
  }
}

extension ReviewTimelinePageInfo {
  init(wire: TimelinePageInfoWire) {
    self.init(
      startCursor: wire.startCursor,
      endCursor: wire.endCursor,
      hasOlder: wire.hasOlder,
      hasNewer: wire.hasNewer
    )
  }
}

extension ReviewsTimelineResponse {
  init(wire: ReviewsTimelineResponseWire) {
    self.init(
      pullRequestId: wire.pullRequestId,
      entries: wire.entries.map(ReviewTimelineEntry.init(wire:)),
      pageInfo: ReviewTimelinePageInfo(wire: wire.pageInfo),
      viewerCanComment: wire.viewerCanComment,
      fetchedAt: wire.fetchedAt
    )
  }
}

extension ReviewsTimelineRequestWire {
  init(_ model: ReviewsTimelineRequest) {
    self.init(
      pullRequestId: model.pullRequestId,
      cursor: model.cursor,
      pageSize: model.pageSize,
      direction: TimelinePageDirectionWire(rawValue: model.direction.rawValue) ?? .older,
      forceRefresh: model.forceRefresh,
      pullRequestUpdatedAt: model.pullRequestUpdatedAt
    )
  }
}
