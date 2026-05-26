import Foundation
import HarnessMonitorCore
import Observation

/// The command composer's editable state and draft-building logic, shared by the
/// iOS and watch composer views. Each view owns one as `@State private var model`
/// and renders a platform Form/List bound to its fields, so the duplicated
/// composer logic lives here once. Platform differences come from the injected
/// `CommandFormProfile`; presentation copy (confirmation wording) stays in the
/// views. The model reads the shared `MirrorStore` for the live snapshot.
@MainActor
@Observable
public final class CommandFormModel {
  public var stationID: String
  public var kind: MobileCommandKind
  public var sessionID: String
  public var agentID: String
  public var taskID: String
  public var reviewID: String
  public var repository: String
  public var reviewNumber: String
  public var batchID: String
  public var acpDecision: String
  public var taskStatus: String
  public var dryRun: Bool
  public var agent: String
  public var role: String
  public var promptPreset: String
  public var prompt: String
  public var label: String
  public var mergeMethod: String
  public var refreshScope: String
  public var auditReason: String
  public var submitting: Bool

  @ObservationIgnored let store: MirrorStore
  @ObservationIgnored let profile: CommandFormProfile

  public init(
    store: MirrorStore,
    profile: CommandFormProfile,
    initialStationID: String = "",
    initialKind: MobileCommandKind = .refresh,
    initialSessionID: String = "",
    initialAgentID: String = "",
    initialTaskID: String = "",
    initialPrompt: String = ""
  ) {
    self.store = store
    self.profile = profile
    self.stationID = initialStationID
    self.kind = initialKind
    self.sessionID = initialSessionID
    self.agentID = initialAgentID
    self.taskID = initialTaskID
    self.reviewID = ""
    self.repository = ""
    self.reviewNumber = ""
    self.batchID = ""
    self.acpDecision = "approve_all"
    self.taskStatus = ""
    self.dryRun = false
    self.agent = "codex"
    self.role = "worker"
    self.promptPreset = "continue"
    self.prompt = initialPrompt
    self.label = profile.defaultLabel
    self.mergeMethod = "squash"
    self.refreshScope = "health"
    self.auditReason = ""
    self.submitting = false
  }
}
