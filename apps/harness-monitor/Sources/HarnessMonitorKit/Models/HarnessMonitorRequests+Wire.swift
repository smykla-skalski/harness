import Foundation

// Maps the rich app request/response models (HarnessMonitorRequests.swift,
// SessionStartRequest.swift, HarnessMonitorAPIClient+AdoptSession.swift) to the
// generated wire types in Models/Generated/SessionRequestsWireTypes.generated.swift.
//
// These are encode-mostly request types: the app builds the rich model and the
// *Wire type owns the snake_case wire shape (explicit CodingKeys). The split is
// load-bearing where the model deliberately diverges from the wire - Int vs UInt8
// progress, the `.locked` queue-policy default, a non-optional observe actor, the
// idiomatic bookmarkID acronym - so call sites keep their ergonomic types. The
// reroute of the API client encode/decode sites onto these wire types is a
// follow-up; this mapping plus the wire-contract test exercise the types now.

extension RoleChangeRequestWire {
  init(_ model: RoleChangeRequest) {
    self.init(actor: model.actor, role: model.role, reason: model.reason)
  }
}

extension AgentRemoveRequestWire {
  init(_ model: AgentRemoveRequest) {
    self.init(actor: model.actor)
  }
}

extension LeaderTransferRequestWire {
  init(_ model: LeaderTransferRequest) {
    self.init(actor: model.actor, newLeaderId: model.newLeaderId, reason: model.reason)
  }
}

extension TaskCreateRequestWire {
  init(_ model: TaskCreateRequest) {
    self.init(
      actor: model.actor,
      title: model.title,
      context: model.context,
      severity: model.severity,
      suggestedFix: model.suggestedFix
    )
  }
}

extension TaskDeleteRequestWire {
  init(_ model: TaskDeleteRequest) {
    self.init(actor: model.actor)
  }
}

extension TaskAssignRequestWire {
  init(_ model: TaskAssignRequest) {
    self.init(actor: model.actor, agentId: model.agentId)
  }
}

extension TaskDropTargetWire {
  init(_ model: TaskDropTarget) {
    switch model {
    case .agent(let agentId):
      self = .agent(agentId: agentId)
    }
  }
}

extension TaskDropRequestWire {
  init(_ model: TaskDropRequest) {
    self.init(
      actor: model.actor,
      target: TaskDropTargetWire(model.target),
      queuePolicy: model.queuePolicy,
      reason: model.reason
    )
  }
}

extension TaskQueuePolicyRequestWire {
  init(_ model: TaskQueuePolicyRequest) {
    self.init(actor: model.actor, queuePolicy: model.queuePolicy)
  }
}

extension TaskUpdateRequestWire {
  init(_ model: TaskUpdateRequest) {
    self.init(actor: model.actor, status: model.status, note: model.note)
  }
}

extension TaskCheckpointRequestWire {
  init(_ model: TaskCheckpointRequest) {
    // The app model carries progress as Int for ergonomic call sites; the wire
    // is the daemon's u8 (0...100).
    self.init(actor: model.actor, summary: model.summary, progress: UInt8(clamping: model.progress))
  }
}

extension SessionEndRequestWire {
  init(_ model: SessionEndRequest) {
    self.init(actor: model.actor)
  }
}

extension SessionArchiveRequestWire {
  init(_ model: SessionArchiveRequest) {
    self.init(actor: model.actor)
  }
}

extension SignalSendRequestWire {
  init(_ model: SignalSendRequest) {
    self.init(
      actor: model.actor,
      agentId: model.agentId,
      command: model.command,
      message: model.message,
      actionHint: model.actionHint
    )
  }
}

extension ObserveSessionRequestWire {
  init(_ model: ObserveSessionRequest) {
    self.init(actor: model.actor)
  }
}

extension SessionStartRequestWire {
  init(_ model: SessionStartRequest) {
    self.init(
      title: model.title,
      context: model.context,
      sessionId: model.sessionId,
      projectDir: model.projectDir,
      policyPreset: model.policyPreset,
      baseRef: model.baseRef
    )
  }
}

extension SignalCancelRequestWire {
  init(_ model: SignalCancelRequest) {
    self.init(actor: model.actor, agentId: model.agentId, signalId: model.signalId)
  }
}

extension TaskSubmitForReviewRequestWire {
  init(_ model: TaskSubmitForReviewRequest) {
    self.init(actor: model.actor, summary: model.summary, suggestedPersona: model.suggestedPersona)
  }
}

extension TaskClaimReviewRequestWire {
  init(_ model: TaskClaimReviewRequest) {
    self.init(actor: model.actor)
  }
}

extension TaskSubmitReviewRequestWire {
  init(_ model: TaskSubmitReviewRequest) {
    self.init(
      actor: model.actor,
      verdict: model.verdict,
      summary: model.summary,
      points: model.points
    )
  }
}

extension TaskRespondReviewRequestWire {
  init(_ model: TaskRespondReviewRequest) {
    self.init(
      actor: model.actor,
      agreed: model.agreed,
      disputed: model.disputed,
      note: model.note
    )
  }
}

extension TaskArbitrateRequestWire {
  init(_ model: TaskArbitrateRequest) {
    self.init(actor: model.actor, verdict: model.verdict, summary: model.summary)
  }
}

extension ImproverApplyRequestWire {
  init(_ model: ImproverApplyRequest) {
    self.init(
      actor: model.actor,
      issueId: model.issueId,
      target: model.target,
      relPath: model.relPath,
      newContents: model.newContents,
      projectDir: model.projectDir,
      dryRun: model.dryRun
    )
  }
}

extension AdoptSessionRequestWire {
  init(_ model: AdoptSessionRequest) {
    self.init(bookmarkId: model.bookmarkID, sessionRoot: model.sessionRoot)
  }
}

extension SessionArchiveResponse {
  init(wire: SessionArchiveResponseWire) {
    self.init(sessionId: wire.sessionId, archivedAt: wire.archivedAt)
  }
}
